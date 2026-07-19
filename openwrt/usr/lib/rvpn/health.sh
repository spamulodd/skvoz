#!/bin/sh
. /usr/lib/rvpn/common.sh

RVPN_LOAD_LOG=$RVPN_RUN/load-hourly.log
RVPN_LOAD_MAX_LINES=168

health_preflight() {
	if ! wan_ok; then
		log "ERROR: WAN down — abort start"
		return 1
	fi
	return 0
}

clash_auth_hdr() {
	sec=$(uci_get clash_secret)
	[ -n "$sec" ] || sec=$(ensure_clash_secret)
	echo "Authorization: Bearer $sec"
}

clash_proxy_json() {
	api=$(clash_api_local)
	curl -sS --connect-timeout 2 --max-time 4 \
		-H "$(clash_auth_hdr)" \
		"http://${api}/proxies/rvpn-urltest" 2>/dev/null
}

clash_node_now() {
	body=$1
	echo "$body" | sed -n 's/.*"now"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

clash_node_delay_ms() {
	body=$1
	delay=$(echo "$body" | grep -o '"delay"[[:space:]]*:[[:space:]]*[0-9][0-9]*' | tail -1 | sed 's/.*:[[:space:]]*//')
	[ -n "$delay" ] || delay=0
	echo "$delay"
}

# 1-min loadavg * 100 (integer), BusyBox-safe
health_loadavg_x100() {
	awk '{ printf "%d", ($1 * 100) + 0.5 }' /proc/loadavg 2>/dev/null || echo 0
}

health_lan_clients() {
	# Unique IPv4 neighbors on br-lan (DHCP/Wi‑Fi clients)
	awk '
		$6 == "br-lan" && $1 ~ /^[0-9]+\./ { c[$1]=1 }
		END { n=0; for (i in c) n++; print n+0 }
	' /proc/net/arp 2>/dev/null || echo 0
}

health_wan_iface() {
	dev=$(uci -q get network.wan.device)
	[ -n "$dev" ] || dev=$(uci -q get network.wan.ifname)
	if [ -z "$dev" ] || [ ! -d "/sys/class/net/$dev" ]; then
		dev=$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')
	fi
	echo "$dev"
}

health_iface_bytes() {
	iface=$1
	rx=0
	tx=0
	if [ -n "$iface" ] && [ -r "/sys/class/net/$iface/statistics/rx_bytes" ]; then
		rx=$(cat "/sys/class/net/$iface/statistics/rx_bytes" 2>/dev/null || echo 0)
		tx=$(cat "/sys/class/net/$iface/statistics/tx_bytes" 2>/dev/null || echo 0)
	fi
	echo "$rx $tx"
}

# Append one hourly sample. Format (space-separated):
# ts load_x100 mem_avail_kb mem_total_kb lan_clients wan_rx wan_tx vpn_run zap_run
health_load_sample() {
	mkdir -p "$RVPN_RUN"
	ts=$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date)
	load=$(health_loadavg_x100)
	mem_a=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null)
	mem_t=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null)
	clients=$(health_lan_clients)
	wan_if=$(health_wan_iface)
	set -- $(health_iface_bytes "$wan_if")
	rx=$1
	tx=$2
	vpn_run=0
	zap_run=0
	[ -n "$(sb_pids)" ] && vpn_run=1
	if [ -f /tmp/rvpn/nfqws.pid ] && kill -0 "$(cat /tmp/rvpn/nfqws.pid 2>/dev/null)" 2>/dev/null; then
		zap_run=1
	elif pgrep -f '^/opt/rvpn/nfqws' >/dev/null 2>&1; then
		zap_run=1
	fi
	printf '%s %s %s %s %s %s %s %s %s\n' \
		"$ts" "${load:-0}" "${mem_a:-0}" "${mem_t:-0}" "${clients:-0}" \
		"${rx:-0}" "${tx:-0}" "$vpn_run" "$zap_run" >>"$RVPN_LOAD_LOG"
	# Keep ~1 week of hourly samples
	if [ -f "$RVPN_LOAD_LOG" ]; then
		tail -n "$RVPN_LOAD_MAX_LINES" "$RVPN_LOAD_LOG" >"$RVPN_LOAD_LOG.tmp" 2>/dev/null && \
			mv "$RVPN_LOAD_LOG.tmp" "$RVPN_LOAD_LOG"
	fi
	chmod 600 "$RVPN_LOAD_LOG" 2>/dev/null || true
}

# Install OpenWrt cron lines (load hourly + sub hourly tick + CIDR weekly).
# Restart cron only if crontab content changed.
health_cron_install() {
	mkdir -p /etc/crontabs "$RVPN_RUN"
	cronf=/etc/crontabs/root
	[ -f "$cronf" ] || touch "$cronf"
	tmp=$RVPN_RUN/crontab.root.$$
	grep -vE 'skvoz-load|skvoz-cidr|skvoz-sub|skvoz-adblock|health_load_sample|cidr_sync_run|sub_cron_tick|adblock_cron_tick' "$cronf" >"$tmp" 2>/dev/null || : >"$tmp"
	echo '7 * * * * /bin/sh -c ". /usr/lib/rvpn/common.sh; . /usr/lib/rvpn/health.sh; health_load_sample" # skvoz-load' >>"$tmp"
	# Subscription refresh tick (honours each sub's refresh_hours / Profile-Update-Interval)
	echo '23 * * * * /bin/sh -c ". /usr/lib/rvpn/sub.sh; sub_cron_tick" # skvoz-sub' >>"$tmp"
	# Daily DNS adblock list refresh (honours adblock_update_hours)
	echo '41 5 * * * /bin/sh -c ". /usr/lib/rvpn/adblock.sh; adblock_cron_tick" # skvoz-adblock' >>"$tmp"
	# Weekly CIDR refresh (Sun 04:17 UTC) — Telegram/Meta/X/Discord ASN
	echo '17 4 * * 0 /bin/sh -c ". /usr/lib/rvpn/cidr-sync.sh; cidr_sync_run" # skvoz-cidr' >>"$tmp"
	if cmp -s "$tmp" "$cronf" 2>/dev/null; then
		rm -f "$tmp"
		return 0
	fi
	mv "$tmp" "$cronf"
	chmod 600 "$cronf" 2>/dev/null || true
	/etc/init.d/cron enable >/dev/null 2>&1 || true
	/etc/init.d/cron restart >/dev/null 2>&1 || true
	log "rvpn crontab updated (load/sub hourly + adblock daily + cidr weekly)"
}

health_status_json() {
	zap=$(uci_get zapret_enabled)
	vpn=$(uci_get vpn_enabled)
	adb=$(uci_get adblock_enabled)
	zap_run=0
	vpn_run=0
	adb_run=0
	adb_dom=0
	if [ -f /tmp/rvpn/nfqws.pid ] && kill -0 "$(cat /tmp/rvpn/nfqws.pid 2>/dev/null)" 2>/dev/null; then
		zap_run=1
	elif pgrep -f '^/opt/rvpn/nfqws' >/dev/null 2>&1; then
		zap_run=1
	fi
	[ -n "$(sb_pids)" ] && vpn_run=1
	if [ -f /tmp/rvpn/adblock.meta ]; then
		adb_dom=$(sed -n 's/^domains=//p' /tmp/rvpn/adblock.meta | head -1)
	fi
	if [ "$adb" = "1" ] && { [ -L /tmp/dnsmasq.d/rvpn-adblock.conf ] || [ -f /tmp/dnsmasq.d/rvpn-adblock.conf ]; }; then
		adb_run=1
	fi
	wan=0
	wan_ok && wan=1
	mem=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null)
	load=$(health_loadavg_x100)
	clients=$(health_lan_clients)

	node_now=""
	node_delay=0
	if [ "$vpn_run" = 1 ]; then
		proxy_body=$(clash_proxy_json)
		node_now=$(clash_node_now "$proxy_body")
		node_delay=$(clash_node_delay_ms "$proxy_body")
	fi
	[ -n "$node_now" ] || node_now="—"
	node_now_j=$(json_escape "$node_now")

	printf '{"zapret_enabled":%s,"vpn_enabled":%s,"adblock_enabled":%s,"adblock_running":%s,"adblock_domains":%s,"zapret_running":%s,"vpn_running":%s,"wan_ok":%s,"mem_available_kb":%s,"loadavg_x100":%s,"lan_clients":%s,"clash_api":"127.0.0.1:9090","node_now":"%s","node_delay_ms":%s}\n' \
		"${zap:-0}" "${vpn:-0}" "${adb:-0}" "$adb_run" "${adb_dom:-0}" "$zap_run" "$vpn_run" "$wan" "${mem:-0}" "${load:-0}" "${clients:-0}" "$node_now_j" "${node_delay:-0}"
}
