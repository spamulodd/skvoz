#!/bin/sh
# shellcheck disable=SC2034

RVPN_LIB=/usr/lib/rvpn
RVPN_RULES=/usr/share/rvpn/rules
RVPN_RUN=/tmp/rvpn
RVPN_CFG=/etc/config/rvpn
RVPN_SB_JSON=/tmp/rvpn/sing-box.json
RVPN_LOG=/tmp/rvpn/rvpn.log
RVPN_STATE=/tmp/rvpn/state
RVPN_WD_PID=$RVPN_RUN/watchdog.pid
RVPN_SVC_LOCK=$RVPN_RUN/service.lock

mkdir -p "$RVPN_RUN" 2>/dev/null || true
chmod 700 "$RVPN_RUN" 2>/dev/null || true

log() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$RVPN_LOG"
	logger -t rvpn "$*"
}

uci_get() {
	uci -q get "rvpn.main.$1"
}

wan_ok() {
	ping -c1 -W2 192.168.100.1 >/dev/null 2>&1 || ping -c1 -W2 1.1.1.1 >/dev/null 2>&1
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

sb_kill_ours() {
	pids=$(sb_pids)
	[ -n "$pids" ] || return 0
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
	tmp=$RVPN_RUN/vpn-user.new
	list_domains "$RVPN_USER_DOMAINS" | grep -vxF "$d" >"$tmp" || true
	{
		echo "# User VPN domains (quick-add). Merged with vpn-domains.txt."
		cat "$tmp"
	} >"$RVPN_USER_DOMAINS"
	rm -f "$tmp"
	log "vpn-user del: $d"
}

# Merge shipped + user domain lists into one file for JSON builder.
vpn_domains_merged_file() {
	out=$RVPN_RUN/vpn-domains.merged
	: >"$out"
	list_domains "$RVPN_RULES/vpn-domains.txt" >>"$out"
	list_domains "$RVPN_USER_DOMAINS" >>"$out"
	# unique preserve order
	awk '!seen[$0]++' "$out" >"$out.u" && mv "$out.u" "$out"
	echo "$out"
}
