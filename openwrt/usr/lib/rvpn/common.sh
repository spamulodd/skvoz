#!/bin/sh
# shellcheck disable=SC2034

RVPN_LIB=/usr/lib/rvpn
RVPN_RULES=/usr/share/rvpn/rules
RVPN_RUN=/tmp/rvpn
RVPN_CFG=/etc/config/rvpn
RVPN_SB_JSON=/tmp/rvpn/sing-box.json
RVPN_LOG=/tmp/rvpn/rvpn.log
RVPN_STATE=/tmp/rvpn/state

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

list_domains() {
	# strip comments/blank from domain list file
	[ -f "$1" ] || return 0
	sed -e 's/#.*//' -e '/^[[:space:]]*$/d' -e 's/[[:space:]]//g' "$1"
}

json_domain_array() {
	# stdout: "a.com","b.com"
	first=1
	list_domains "$1" | while read -r d; do
		[ -n "$d" ] || continue
		if [ "$first" = 1 ]; then
			printf '"%s"' "$d"
			first=0
		else
			printf ',"%s"' "$d"
		fi
	done
}
