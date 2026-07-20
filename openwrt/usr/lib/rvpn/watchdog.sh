#!/bin/sh
. /usr/lib/rvpn/common.sh
. /usr/lib/rvpn/dns.sh
. /usr/lib/rvpn/nft.sh
. /usr/lib/rvpn/singbox.sh

# Fail-open when sing-box dies: flush VPN nft, restore DNS, then aaaa-only
# if zapret still needs it.
watchdog_failopen() {
	log "WATCHDOG: sing-box dead — DNS/nft fail-open"
	date -u +%Y-%m-%dT%H:%MZ 2>/dev/null >"$RVPN_RUN/last_failopen" || date >"$RVPN_RUN/last_failopen"
	: >"$RVPN_RUN/wd_degraded"
	nft_flush_vpn
	dns_restore
	zap=$(uci_get zapret_enabled)
	if [ "$zap" = "1" ]; then
		dns_apply_aaaa_only
	fi
}

watchdog_recover() {
	log "WATCHDOG: sing-box alive — restore FakeIP/nft"
	dns_apply
	nft_apply_vpn || log "WARN: nft vpn recover failed"
	rm -f "$RVPN_RUN/wd_degraded"
	# Drain deferred Flowseal/nfqws sync (GitHub was blocked at install)
	if [ -f /usr/lib/rvpn/zapret-sync.sh ]; then
		if [ -f "$RVPN_RUN/zapret_sync.pending" ] || [ -f "$RVPN_RUN/nfqws_fetch.pending" ]; then
			# shellcheck source=/dev/null
			. /usr/lib/rvpn/zapret-sync.sh
			zapret_after_vpn_ready >/dev/null 2>&1 || true
		fi
	fi
}

watchdog_reload_in_progress() {
	[ -f "$RVPN_SB_RELOAD_LOCK" ] || return 1
	ts=$(cat "$RVPN_SB_RELOAD_LOCK" 2>/dev/null || echo 0)
	now=$(date +%s 2>/dev/null || echo 0)
	case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
	case "$now" in ''|*[!0-9]*) now=0 ;; esac
	if [ "$now" -eq 0 ] || [ "$ts" -eq 0 ]; then
		if sb_alive; then
			rm -f "$RVPN_SB_RELOAD_LOCK"
			return 1
		fi
		return 0
	fi
	age=$((now - ts))
	if [ "$age" -gt 180 ]; then
		log "WATCHDOG: stale sb reload lock (${age}s) — clearing"
		rm -f "$RVPN_SB_RELOAD_LOCK"
		return 1
	fi
	return 0
}

# Only check nft after fail-open / missing FakeIP mark (avoid nft list every tick).
watchdog_needs_recover() {
	[ -f "$RVPN_RUN/wd_degraded" ] && return 0
	grep -q fakeip /tmp/rvpn/dns.applied 2>/dev/null || return 0
	return 1
}

watchdog_loop() {
	miss=0
	tick=0
	vpn=$(uci_get vpn_enabled)
	while true; do
		sleep 15
		tick=$((tick + 1))
		# Re-read UCI every ~2 min (8 ticks) so toggle without WD restart works
		if [ $((tick % 8)) -eq 0 ]; then
			vpn=$(uci_get vpn_enabled)
		fi
		[ "$vpn" = "1" ] || {
			miss=0
			continue
		}
		if watchdog_reload_in_progress; then
			miss=0
			continue
		fi
		if ! sb_alive; then
			miss=$((miss + 1))
			if [ "$miss" -ge 2 ]; then
				watchdog_failopen
				if sb_start; then
					watchdog_recover
					log "WATCHDOG: sing-box restarted after fail-open"
				else
					log "WATCHDOG: sing-box restart failed — stay fail-open"
				fi
				miss=0
			fi
		else
			miss=0
			if watchdog_needs_recover; then
				# Confirm nft only when degraded/mark wrong
				if ! grep -q fakeip /tmp/rvpn/dns.applied 2>/dev/null || \
					! nft list table inet rvpn_vpn >/dev/null 2>&1; then
					watchdog_recover
				else
					rm -f "$RVPN_RUN/wd_degraded"
				fi
			fi
		fi
	done
}

watchdog_start() {
	watchdog_stop
	/bin/sh -c '
		. /usr/lib/rvpn/common.sh
		. /usr/lib/rvpn/dns.sh
		. /usr/lib/rvpn/nft.sh
		. /usr/lib/rvpn/singbox.sh
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
