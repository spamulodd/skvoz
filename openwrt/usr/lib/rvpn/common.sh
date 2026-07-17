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

mkdir -p "$RVPN_RUN" 2>/dev/null || true

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

norm_bool() {
	case "$1" in
	1|on|true|yes|ON|TRUE|YES) echo 1 ;;
	*) echo 0 ;;
	esac
}

ensure_ui_secret() {
	s=$(uci_get ui_secret)
	if [ -z "$s" ] || [ "$s" = "CHANGE_ME" ]; then
		s=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | hexdump -v -e '/1 "%02x"' 2>/dev/null)
		[ -n "$s" ] || s=$(date +%s)-$$
		uci set rvpn.main.ui_secret="$s"
		uci commit rvpn
		log "generated ui_secret"
	fi
	echo "$s"
}

ensure_clash_secret() {
	s=$(uci_get clash_secret)
	if [ -z "$s" ]; then
		s=$(dd if=/dev/urandom bs=12 count=1 2>/dev/null | hexdump -v -e '/1 "%02x"' 2>/dev/null)
		[ -n "$s" ] || s=skvoz-local
		uci set rvpn.main.clash_secret="$s"
		uci commit rvpn
	fi
	echo "$s"
}

clash_api_local() {
	# always probe via loopback
	echo "127.0.0.1:9090"
}

sb_pids() {
	# PIDs of our sing-box instance only
	pgrep -f '/tmp/rvpn/sing-box.json' 2>/dev/null
}

sb_kill_ours() {
	pids=$(sb_pids)
	[ -n "$pids" ] || return 0
	for p in $pids; do
		kill -9 "$p" 2>/dev/null || true
	done
}

list_domains() {
	[ -f "$1" ] || return 0
	sed -e 's/#.*//' -e '/^[[:space:]]*$/d' -e 's/[[:space:]]//g' "$1"
}
