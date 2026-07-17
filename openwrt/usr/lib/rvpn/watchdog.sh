#!/bin/sh
. /usr/lib/rvpn/common.sh
. /usr/lib/rvpn/dns.sh
. /usr/lib/rvpn/nft.sh

# Fail-open when sing-box dies: flush VPN nft, restore DNS, then aaaa-only
# if zapret still needs it. NEVER re-apply FakeIP until sing-box is back.
watchdog_failopen() {
	log "WATCHDOG: sing-box dead — DNS/nft fail-open"
	nft_flush_vpn
	dns_restore
	zap=$(uci_get zapret_enabled)
	if [ "$zap" = "1" ]; then
		dns_apply_aaaa_only
	fi
}

watchdog_loop() {
	while true; do
		sleep 15
		vpn=$(uci_get vpn_enabled)
		[ "$vpn" = "1" ] || continue
		grep -q fakeip /tmp/rvpn/dns.applied 2>/dev/null || continue
		if [ -z "$(sb_pids)" ]; then
			watchdog_failopen
		fi
	done
}

watchdog_start() {
	watchdog_stop
	/bin/sh -c '
		. /usr/lib/rvpn/common.sh
		. /usr/lib/rvpn/dns.sh
		. /usr/lib/rvpn/nft.sh
		. /usr/lib/rvpn/watchdog.sh
		watchdog_loop
	' >/dev/null 2>&1 &
	echo $! >"$RVPN_WD_PID"
	log "watchdog started pid=$(cat "$RVPN_WD_PID")"
}

watchdog_stop() {
	if [ -f "$RVPN_WD_PID" ]; then
		kill "$(cat "$RVPN_WD_PID")" 2>/dev/null || true
		rm -f "$RVPN_WD_PID"
	fi
}
