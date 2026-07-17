#!/bin/sh
. /usr/lib/rvpn/common.sh
. /usr/lib/rvpn/dns.sh
. /usr/lib/rvpn/nft.sh

watchdog_loop() {
	while true; do
		sleep 15
		vpn=$(uci_get vpn_enabled)
		[ "$vpn" = "1" ] || continue
		[ -f /tmp/rvpn/dns.applied ] || continue
		if [ -z "$(sb_pids)" ]; then
			log "WATCHDOG: sing-box dead — DNS/nft fail-open"
			nft_flush_vpn
			dns_restore
		fi
	done
}

watchdog_start() {
	watchdog_stop
	# run loop in background without re-entering this file
	/bin/sh -c '
		. /usr/lib/rvpn/common.sh
		. /usr/lib/rvpn/dns.sh
		. /usr/lib/rvpn/nft.sh
		while true; do
			sleep 15
			vpn=$(uci_get vpn_enabled)
			[ "$vpn" = "1" ] || continue
			[ -f /tmp/rvpn/dns.applied ] || continue
			if [ -z "$(sb_pids)" ]; then
				log "WATCHDOG: sing-box dead — DNS/nft fail-open"
				nft_flush_vpn
				dns_restore
			fi
		done
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
