#!/bin/sh
. /usr/lib/rvpn/common.sh

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

health_status_json() {
	zap=$(uci_get zapret_enabled)
	vpn=$(uci_get vpn_enabled)
	zap_run=0
	vpn_run=0
	if pgrep -f '/opt/rvpn/nfqws' >/dev/null 2>&1 || pgrep -x nfqws >/dev/null 2>&1; then
		zap_run=1
	fi
	[ -n "$(sb_pids)" ] && vpn_run=1
	wan=0
	wan_ok && wan=1
	mem=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null)

	node_now=""
	node_delay=0
	if [ "$vpn_run" = 1 ]; then
		proxy_body=$(clash_proxy_json)
		node_now=$(clash_node_now "$proxy_body")
		node_delay=$(clash_node_delay_ms "$proxy_body")
	fi
	[ -n "$node_now" ] || node_now="—"
	node_now_j=$(json_escape "$node_now")

	printf '{"zapret_enabled":%s,"vpn_enabled":%s,"zapret_running":%s,"vpn_running":%s,"wan_ok":%s,"mem_available_kb":%s,"clash_api":"127.0.0.1:9090","node_now":"%s","node_delay_ms":%s}\n' \
		"${zap:-0}" "${vpn:-0}" "$zap_run" "$vpn_run" "$wan" "${mem:-0}" "$node_now_j" "${node_delay:-0}"
}
