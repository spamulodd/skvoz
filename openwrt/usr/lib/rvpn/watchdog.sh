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
	miss=0
	while true; do
		sleep 15
		vpn=$(uci_get vpn_enabled)
		[ "$vpn" = "1" ] || {
			miss=0
			continue
		}
		# Ignore brief gap during sb_reload_domains
		[ -f "$RVPN_SB_RELOAD_LOCK" ] && {
			miss=0
			continue
		}
		grep -q fakeip /tmp/rvpn/dns.applied 2>/dev/null || {
			miss=0
			continue
		}
		if [ -z "$(sb_pids)" ]; then
			miss=$((miss + 1))
			# Require 2 consecutive misses (~30s) so reload/restart does not fail-open
			if [ "$miss" -ge 2 ]; then
				watchdog_failopen
				miss=0
			fi
		else
			miss=0
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
