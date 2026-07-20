#!/bin/sh
[ "${RVPN_SELFTEST_SOURCED:-0}" = "1" ] && return 0
RVPN_SELFTEST_SOURCED=1

. /usr/lib/rvpn/common.sh

selftest_run() {
	mkdir -p "$RVPN_RUN"
	out=/tmp/rvpn/selftest.json
	
	passed=0
	total=0
	checks=""
	
	add_check() {
		id=$1
		ok=$2
		detail=$3
		
		[ "$ok" = "1" ] && passed=$((passed + 1))
		total=$((total + 1))
		
		dj=$(json_escape "$detail")
		
		if [ -z "$checks" ]; then
			checks="{\"id\":\"$id\",\"ok\":$ok,\"detail\":\"$dj\"}"
		else
			checks="$checks,{\"id\":\"$id\",\"ok\":$ok,\"detail\":\"$dj\"}"
		fi
	}

	# 1. wan_ok
	if ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 || ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
		add_check "wan_ok" 1 "WAN is reachable"
	else
		add_check "wan_ok" 0 "WAN is unreachable"
	fi
	
	# 2. dns.applied
	dns_mode=$(cat "$RVPN_RUN/dns.applied" 2>/dev/null || echo "missing")
	if [ "$dns_mode" != "missing" ] && [ "$dns_mode" != "off" ]; then
		add_check "dns_applied" 1 "DNS applied: $dns_mode"
	else
		add_check "dns_applied" 0 "DNS not applied or off"
	fi
	
	# 3. sb_alive/sing-box
	if sb_alive; then
		add_check "sing_box" 1 "sing-box is running"
	else
		add_check "sing_box" 0 "sing-box is not running"
	fi
	
	# 4. nfqws
	nfq=0
	if [ -f "$RVPN_RUN/nfqws.pid" ] && kill -0 "$(cat "$RVPN_RUN/nfqws.pid" 2>/dev/null)" 2>/dev/null; then
		nfq=1
	elif pgrep -f '^/opt/rvpn/nfqws' >/dev/null 2>&1; then
		nfq=1
	fi
	if [ "$nfq" = "1" ]; then
		add_check "nfqws" 1 "nfqws is running"
	else
		add_check "nfqws" 0 "nfqws is not running"
	fi
	
	# 5. nft rvpn_vpn/rvpn_zapret
	if nft list table inet rvpn_vpn >/dev/null 2>&1; then
		add_check "nft_vpn" 1 "nft table rvpn_vpn exists"
	else
		add_check "nft_vpn" 0 "nft table rvpn_vpn missing"
	fi
	if nft list table inet rvpn_zapret >/dev/null 2>&1; then
		add_check "nft_zapret" 1 "nft table rvpn_zapret exists"
	else
		add_check "nft_zapret" 0 "nft table rvpn_zapret missing"
	fi
	
	# 6. current zapret_strategy
	strat=$(uci_get zapret_strategy)
	if [ -n "$strat" ]; then
		add_check "zapret_strategy" 1 "Strategy: $strat"
	else
		add_check "zapret_strategy" 0 "Strategy not set"
	fi
	
	# 7. ui setup_done
	setup_done=$(uci_get setup_done)
	if [ "$setup_done" = "1" ]; then
		add_check "setup_done" 1 "Setup is done"
	else
		add_check "setup_done" 0 "Setup not done"
	fi
	
	# 8. github pending flags
	sync_pending=0
	{ [ -f "$RVPN_RUN/zapret_sync.pending" ] || [ -f "$RVPN_RUN/nfqws_fetch.pending" ]; } && sync_pending=1
	if [ "$sync_pending" = "0" ]; then
		add_check "github_sync" 1 "No pending sync"
	else
		add_check "github_sync" 0 "GitHub sync pending"
	fi
	
	# 9. HTTPS probes (real IP via 1.1.1.1 — bypass FakeIP DNS)
	selftest_probe() {
		host=$1
		path=$2
		ip=
		if command -v nslookup >/dev/null 2>&1; then
			ip=$(nslookup "$host" 1.1.1.1 2>/dev/null | awk '/^Address: /{a=$2} END{print a}' | grep -E '^[0-9]+\.')
		fi
		[ -n "$ip" ] || {
			echo "0 fail"
			return 1
		}
		code=$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' \
			--connect-timeout 4 --max-time 10 \
			--resolve "${host}:443:${ip}" \
			"https://${host}${path}" 2>/dev/null) || code="000 9"
		http=${code%% *}
		sec=${code##* }
		ms=$(echo "$sec" | awk '{printf "%d", $1*1000}')
		case "$http" in
		200|204|301|302|303|307|308|401|403) echo "$ms ok"; return 0 ;;
		*) echo "${ms:-0} fail"; return 1 ;;
		esac
	}
	for probe in "www.google.com|/generate_204" "discord.com|/" "rutracker.org|/"; do
		host=${probe%%|*}
		path=${probe##*|}
		res=$(selftest_probe "$host" "$path")
		st=${res##* }
		ms=${res%% *}
		if [ "$st" = "ok" ]; then
			add_check "probe_$host" 1 "OK (${ms}ms)"
		else
			add_check "probe_$host" 0 "Failed (${ms}ms)"
		fi
	done
	
	ok=0
	[ "$passed" = "$total" ] && ok=1
	
	ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date)
	
	printf '{"ok":%s,"passed":%s,"total":%s,"checks":[%s],"ts":"%s"}\n' \
		"$ok" "$passed" "$total" "$checks" "$ts" | tee "$out"
}
