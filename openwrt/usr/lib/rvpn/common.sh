#!/bin/sh
# shellcheck disable=SC2034
# Idempotent source (CGI loads many libs that all pull common).
[ "${RVPN_COMMON_SOURCED:-0}" = "1" ] && return 0
RVPN_COMMON_SOURCED=1

RVPN_LIB=/usr/lib/rvpn
RVPN_RULES=/usr/share/rvpn/rules
RVPN_RUN=/tmp/rvpn
RVPN_CFG=/etc/config/rvpn
RVPN_SB_JSON=/tmp/rvpn/sing-box.json
RVPN_LOG=/tmp/rvpn/rvpn.log
RVPN_STATE=/tmp/rvpn/state
RVPN_WD_PID=$RVPN_RUN/watchdog.pid
RVPN_SVC_LOCK=$RVPN_RUN/service.lock
RVPN_SB_RELOAD_LOCK=$RVPN_RUN/sb_reloading
RVPN_SB_RELOAD_FLOCK=$RVPN_RUN/sb_reload.flock

mkdir -p "$RVPN_RUN" 2>/dev/null || true
chmod 700 "$RVPN_RUN" 2>/dev/null || true

log() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$RVPN_LOG"
	logger -t rvpn "$*"
}

uci_get() {
	uci -q get "rvpn.main.$1"
}

# Cached WAN probe (file, ~45s) — UI/status must not ping every request.
wan_ok() {
	c=$RVPN_RUN/wan_ok.cache
	now=$(date +%s 2>/dev/null || echo 0)
	if [ -f "$c" ] && [ "$now" != 0 ]; then
		# format: ts val
		read -r ts val <<EOF
$(cat "$c" 2>/dev/null)
EOF
		case "$ts" in ''|*[!0-9]*) ;; *)
			age=$((now - ts))
			if [ "$age" -ge 0 ] && [ "$age" -lt 45 ]; then
				[ "$val" = "1" ]
				return $?
			fi
			;;
		esac
	fi
	ok=0
	if ping -c1 -W2 192.168.100.1 >/dev/null 2>&1 || ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
		ok=1
	fi
	mkdir -p "$RVPN_RUN" 2>/dev/null || true
	echo "$now $ok" >"$c" 2>/dev/null || true
	[ "$ok" = "1" ]
}

# sing-box alive via pidfile (cheap); falls back to pgrep.
sb_alive() {
	if [ -f "$RVPN_RUN/sing-box.pid" ]; then
		kill -0 "$(cat "$RVPN_RUN/sing-box.pid" 2>/dev/null)" 2>/dev/null && return 0
	fi
	[ -n "$(sb_pids)" ]
}

# Local mixed inbound (sing-box) — app-store / GitHub fetches when VPN is up.
RVPN_MIXED_PROXY=${RVPN_MIXED_PROXY:-127.0.0.1:10808}

# True when VPN layer is on and sing-box can proxy local curl.
rvpn_proxy_ready() {
	[ "$(uci_get vpn_enabled)" = "1" ] || return 1
	sb_alive || return 1
	return 0
}

# curl wrapper: prefer HTTP proxy via sing-box mixed-in (GitHub etc. → VPN).
# Falls back to direct if proxy fails or VPN off.
# Usage: rvpn_curl [curl args...]   (do not pass -x yourself)
rvpn_curl() {
	if rvpn_proxy_ready; then
		if curl --proxy "http://${RVPN_MIXED_PROXY}" "$@"; then
			return 0
		fi
		log "rvpn_curl: proxy ${RVPN_MIXED_PROXY} failed — retry direct"
	fi
	curl "$@"
}

# Escape string for JSON "..."
json_escape() {
	printf '%s' "$1" | awk '
		BEGIN { ORS="" }
		{
			gsub(/\\/, "\\\\")
			gsub(/"/, "\\\"")
			gsub(/\t/, "\\t")
			gsub(/\r/, "\\r")
			gsub(/\n/, "\\n")
			print
		}'
}

# Port 1–65535
valid_port() {
	case "$1" in
	''|*[!0-9]*) return 1 ;;
	esac
	[ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# IPv4 CIDR a.b.c.d/n
valid_ipv4_cidr() {
	echo "$1" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$'
}

# Domain-ish token for lists
valid_domain_token() {
	echo "$1" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$'
}

# UCI section name safe for shell/uci (never main / nodes via this helper alone).
valid_uci_name() {
	case "$1" in
	''|*[!A-Za-z0-9_]*|main) return 1 ;;
	esac
	return 0
}

# Subscription URL: http(s) only; reject shell/uci metacharacters.
valid_sub_url() {
	case "$1" in
	https://*|http://*) ;;
	*) return 1 ;;
	esac
	case "$1" in
	*[\`\$\(\)\;\"\'\|\&\<\>\\]*) return 1 ;;
	esac
	# Reasonable length
	[ "${#1}" -ge 12 ] && [ "${#1}" -le 2048 ]
}

# True if rvpn.$1 is an existing subscription section.
uci_is_subscription() {
	sid=$1
	valid_uci_name "$sid" || return 1
	uci -q show "rvpn.$sid" 2>/dev/null | grep -q "^rvpn\\.$sid=subscription$"
}

# Count matching lines; never append a second "0" on grep exit 1.
count_grep() {
	# usage: count_grep PATTERN FILE
	pat=$1
	file=$2
	[ -f "$file" ] || { echo 0; return 0; }
	n=$(grep -cE "$pat" "$file" 2>/dev/null || true)
	case "$n" in
	''|*[!0-9]*) echo 0 ;;
	*) echo "$n" ;;
	esac
}

norm_bool() {
	case "$1" in
	1|on|true|yes|ON|TRUE|YES) echo 1 ;;
	*) echo 0 ;;
	esac
}

# Strong random hex; empty on failure (no weak fallbacks).
rand_hex() {
	bytes=${1:-16}
	s=$(dd if=/dev/urandom bs="$bytes" count=1 2>/dev/null | hexdump -v -e '/1 "%02x"' 2>/dev/null)
	[ -n "$s" ] && [ "${#s}" -ge 16 ] && { echo "$s"; return 0; }
	if [ -r /proc/sys/kernel/random/uuid ]; then
		tr -d '-' </proc/sys/kernel/random/uuid
		return 0
	fi
	return 1
}

ensure_ui_secret() {
	s=$(uci_get ui_secret)
	if [ -z "$s" ] || [ "$s" = "CHANGE_ME" ]; then
		s=$(rand_hex 16) || {
			log "ERROR: cannot generate ui_secret (no entropy)"
			return 1
		}
		uci set rvpn.main.ui_secret="$s"
		uci commit rvpn
		log "generated ui_secret"
	fi
	echo "$s"
}

ensure_clash_secret() {
	s=$(uci_get clash_secret)
	if [ -z "$s" ] || [ "$s" = "skvoz-local" ]; then
		s=$(rand_hex 12) || {
			log "ERROR: cannot generate clash_secret (no entropy)"
			return 1
		}
		uci set rvpn.main.clash_secret="$s"
		uci commit rvpn
		log "generated clash_secret"
	fi
	echo "$s"
}

clash_api_local() {
	echo "127.0.0.1:9090"
}

sb_pids() {
	pgrep -f '/tmp/rvpn/sing-box.json' 2>/dev/null
}

# TERM first (graceful), then KILL leftovers — less FakeIP/cache disruption.
sb_kill_ours() {
	pids=$(sb_pids)
	[ -n "$pids" ] || return 0
	for p in $pids; do
		kill "$p" 2>/dev/null || true
	done
	i=0
	while [ "$i" -lt 5 ]; do
		[ -z "$(sb_pids)" ] && return 0
		sleep 1
		i=$((i + 1))
	done
	pids=$(sb_pids)
	for p in $pids; do
		kill -9 "$p" 2>/dev/null || true
	done
}

# Serialize init.d actions (CGI / rvpnctl).
# BusyBox flock has no -w: poll flock -n on FD, then run under held lock.
rvpn_with_lock() {
	mkdir -p "$RVPN_RUN"
	if ! command -v flock >/dev/null 2>&1; then
		"$@"
		return $?
	fi
	(
		i=0
		while ! flock -n 9; do
			i=$((i + 1))
			if [ "$i" -gt 120 ]; then
				log "rvpn_with_lock: timeout after 120s"
				exit 1
			fi
			sleep 1
		done
		"$@"
	) 9>"$RVPN_SVC_LOCK"
}

list_domains() {
	[ -f "$1" ] || return 0
	sed -e 's/#.*//' -e '/^[[:space:]]*$/d' -e 's/[[:space:]]//g' "$1"
}

RVPN_USER_DOMAINS=$RVPN_RULES/vpn-user.txt

# Normalize host: strip scheme/path, lowercase.
normalize_domain() {
	d=$1
	d=$(printf '%s' "$d" | sed -e 's|^[Hh][Tt][Tt][Pp][Ss]*://||' -e 's|/.*||' -e 's|:.*||' -e 's/^www\.//')
	printf '%s' "$d" | tr 'A-Z' 'a-z'
}

domain_in_file() {
	f=$1
	d=$2
	[ -f "$f" ] || return 1
	list_domains "$f" | grep -qxF "$d"
}

# Append to vpn-user.txt (idempotent).
vpn_user_add() {
	d=$(normalize_domain "$1")
	valid_domain_token "$d" || {
		log "ERROR: bad domain '$1'"
		return 1
	}
	mkdir -p "$RVPN_RULES"
	touch "$RVPN_USER_DOMAINS"
	if domain_in_file "$RVPN_RULES/vpn-domains.txt" "$d" || domain_in_file "$RVPN_USER_DOMAINS" "$d"; then
		log "domain already listed: $d"
		return 0
	fi
	printf '%s\n' "$d" >>"$RVPN_USER_DOMAINS"
	log "vpn-user add: $d"
	return 0
}

vpn_user_del() {
	d=$(normalize_domain "$1")
	[ -f "$RVPN_USER_DOMAINS" ] || return 0
	tmp=$RVPN_RUN/vpn-user.$$
	list_domains "$RVPN_USER_DOMAINS" | grep -vxF "$d" >"$tmp" || true
	{
		echo "# User VPN domains (quick-add). Merged with vpn-domains.txt."
		cat "$tmp"
	} >"$RVPN_USER_DOMAINS"
	rm -f "$tmp"
	log "vpn-user del: $d"
}

# Merge shipped + user into $1 path; echo path. Atomic replace.
rules_merge_lists() {
	out=$1
	shift
	tmp=$out.$$
	: >"$tmp"
	for f in "$@"; do
		[ -f "$f" ] && list_domains "$f" >>"$tmp"
	done
	awk '!seen[$0]++' "$tmp" >"$tmp.u" && mv "$tmp.u" "$out"
	rm -f "$tmp"
	echo "$out"
}

RVPN_DPI_USER=$RVPN_RULES/dpi-user.txt
RVPN_GAMES_USER=$RVPN_RULES/games-user.txt

dpi_hostlist_merged_file() {
	# Prefer Flowseal-aware merge when strat lib is present
	if [ -f /usr/lib/rvpn/zapret-strat.sh ]; then
		# shellcheck source=/dev/null
		. /usr/lib/rvpn/zapret-strat.sh
		zapret_hostlist_build "$RVPN_RUN/dpi.merged"
		return 0
	fi
	rules_merge_lists "$RVPN_RUN/dpi.merged" "$RVPN_RULES/dpi.txt" "$RVPN_DPI_USER"
}

games_domains_merged_file() {
	rules_merge_lists "$RVPN_RUN/games-domains.merged" "$RVPN_RULES/games-domains.txt" "$RVPN_GAMES_USER"
}

# Merge shipped + user domain lists into one file for JSON builder.
vpn_domains_merged_file() {
	rules_merge_lists "$RVPN_RUN/vpn-domains.merged" "$RVPN_RULES/vpn-domains.txt" "$RVPN_USER_DOMAINS"
}
