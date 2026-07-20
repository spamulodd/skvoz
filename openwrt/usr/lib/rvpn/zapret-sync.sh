#!/bin/sh
# Sync Flowseal lists (and optional strategy refresh) from GitHub.
# If GitHub is blocked: warn + pending marker; retry after VPN is up.
[ "${RVPN_ZAPRET_SYNC_SOURCED:-0}" = "1" ] && return 0
RVPN_ZAPRET_SYNC_SOURCED=1

. /usr/lib/rvpn/common.sh

ZAP_STRAT_DIR=/usr/share/rvpn/zapret-strategies
ZAP_FAKE_DIR=/usr/share/rvpn/fake
ZAP_SYNC_PENDING=$RVPN_RUN/zapret_sync.pending
ZAP_SYNC_WARN=$RVPN_RUN/zapret_sync.warn
ZAP_SYNC_OK=$RVPN_RUN/zapret_sync.ok
FLOWSEAL_RAW=https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main
FLOWSEAL_PROBE=https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/lists/list-general.txt

zapret_github_reachable() {
	# Short probe — prefer VPN proxy when sing-box is up
	rvpn_curl -sS --connect-timeout 4 --max-time 12 -o /dev/null -w '%{http_code}' \
		"$FLOWSEAL_PROBE" 2>/dev/null | grep -qE '^(200|301|302)$'
}

zapret_sync_warn() {
	msg=$1
	printf '%s\n' "$msg" >"$ZAP_SYNC_WARN"
	log "WARN: $msg"
}

zapret_sync_mark_pending() {
	reason=${1:-github_blocked}
	mkdir -p "$RVPN_RUN"
	printf '%s\n' "$reason" >"$ZAP_SYNC_PENDING"
	zapret_sync_warn "GitHub (Flowseal) недоступен — списки/обновления стратегий отложены до настройки VPN. Используются встроенные копии."
}

zapret_sync_clear_pending() {
	rm -f "$ZAP_SYNC_PENDING" "$ZAP_SYNC_WARN" 2>/dev/null || true
}

zapret_sync_fetch_file() {
	url=$1
	dest=$2
	tmp=$dest.tmp.$$
	if rvpn_curl -sS --connect-timeout 5 --max-time 60 -L -o "$tmp" "$url" 2>/dev/null && [ -s "$tmp" ]; then
		mv "$tmp" "$dest"
		return 0
	fi
	rm -f "$tmp"
	return 1
}

# Download Flowseal lists + fake bins into share dir.
zapret_sync_run() {
	mkdir -p "$ZAP_STRAT_DIR/lists" "$ZAP_FAKE_DIR" "$RVPN_RUN"
	if ! zapret_github_reachable; then
		zapret_sync_mark_pending github_blocked
		return 1
	fi

	ok=0
	fail=0
	for f in list-general.txt list-exclude.txt list-google.txt ipset-exclude.txt; do
		if zapret_sync_fetch_file "$FLOWSEAL_RAW/lists/$f" "$ZAP_STRAT_DIR/lists/$f"; then
			ok=$((ok + 1))
		else
			fail=$((fail + 1))
			log "WARN: sync list failed: $f"
		fi
	done
	for f in stun.bin tls_clienthello_max_ru.bin tls_clienthello_www_google_com.bin \
		tls_clienthello_4pda_to.bin quic_initial_www_google_com.bin quic_initial_dbankcloud_ru.bin; do
		if zapret_sync_fetch_file "$FLOWSEAL_RAW/bin/$f" "$ZAP_FAKE_DIR/$f"; then
			ok=$((ok + 1))
		else
			fail=$((fail + 1))
		fi
	done

	date -u +%Y-%m-%dT%H:%MZ >"$ZAP_SYNC_OK" 2>/dev/null || date >"$ZAP_SYNC_OK"
	echo "ok=$ok fail=$fail" >>"$ZAP_SYNC_OK"
	if [ "$ok" -gt 0 ]; then
		zapret_sync_clear_pending
		log "zapret sync OK files=$ok fail=$fail"
		return 0
	fi
	zapret_sync_mark_pending sync_failed
	return 1
}

# First install: try sync; on block → warn + pending (shipped strategies still work).
zapret_bootstrap_first_install() {
	mkdir -p "$RVPN_RUN" "$ZAP_STRAT_DIR/lists"
	# Already have vendored lists? still try update
	if zapret_github_reachable; then
		zapret_sync_run && return 0
	fi
	zapret_sync_mark_pending github_blocked
	# Ensure marker visible for UI
	return 1
}

# Call after VPN is up — drain pending sync + nfqws + optional auto-test.
zapret_after_vpn_ready() {
	did=0
	if [ -f "$ZAP_SYNC_PENDING" ]; then
		log "zapret: VPN up — retry Flowseal sync (was pending)"
		zapret_sync_run && did=1
	fi
	if [ -f /usr/lib/rvpn/nfqws-fetch.sh ]; then
		# shellcheck source=/dev/null
		. /usr/lib/rvpn/nfqws-fetch.sh
		nfqws_after_vpn_ready && did=1
	fi
	if [ -f "$RVPN_RUN/update.pending" ] && [ -f /usr/lib/rvpn/update.sh ]; then
		# shellcheck source=/dev/null
		. /usr/lib/rvpn/update.sh
		log "zapret: VPN up — retry Skvoz update (was pending)"
		update_run >/dev/null 2>&1 && did=1 || true
	fi
	if [ "$did" = "1" ] && [ "$(uci_get zapret_enabled)" = "1" ]; then
		# shellcheck source=/dev/null
		. /usr/lib/rvpn/zapret-test.sh
		zapret_test_autotune >/dev/null 2>&1 || true
	fi
	[ "$did" = "1" ]
}
