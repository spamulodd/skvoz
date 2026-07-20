#!/bin/sh
. /usr/lib/rvpn/common.sh
. /usr/lib/rvpn/health.sh
. /usr/lib/rvpn/singbox.sh
. /usr/lib/rvpn/adblock.sh
. /usr/lib/rvpn/ui-api.sh

qs=${QUERY_STRING:-status}
cmd=${qs%%&*}

get_arg() {
	echo "$qs" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1 | sed 's/+/ /g' | sed 's/%3A/:/g;s/%2F/\//g;s/%3a/:/g;s/%2f/\//g'
}

# Minimal URL-decode for domain/URL args
urldecode() {
	printf '%b' "$(printf '%s' "$1" | sed 's/+/ /g;s/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')"
}

json_hdr() {
	echo "Content-Type: application/json; charset=utf-8"
	echo "Cache-Control: no-store"
	echo ""
}

text_hdr() {
	echo "Content-Type: text/plain; charset=utf-8"
	echo "Cache-Control: no-store"
	echo ""
}

require_auth() {
	want=$(ensure_ui_secret) || {
		echo "Status: 503 Service Unavailable"
		json_hdr
		echo '{"error":"no_ui_secret"}'
		exit 0
	}
	# Prefer Cookie / header (less log leakage); query token remains fallback for uhttpd.
	got=
	if [ -n "$HTTP_COOKIE" ]; then
		got=$(echo "$HTTP_COOKIE" | tr ';' '\n' | sed -n 's/^[[:space:]]*skvoz_token=//p' | head -1)
	fi
	[ -z "$got" ] && got=$HTTP_X_SKVOZ_TOKEN
	[ -z "$got" ] && got=$(get_arg token)
	if [ -z "$got" ] || [ "$got" != "$want" ]; then
		echo "Status: 401 Unauthorized"
		json_hdr
		echo '{"error":"unauthorized"}'
		exit 0
	fi
}

svc_async() {
	action=$1
	(
		rvpn_with_lock /etc/init.d/rvpn "$action" >>"$RVPN_LOG" 2>&1
	) &
}

case "$cmd" in
ping_public)
	json_hdr
	echo '{"ok":1,"auth":1,"name":"Skvoz"}'
	;;
status)
	require_auth
	json_hdr
	health_status_json
	;;
snapshot)
	require_auth
	json_hdr
	ui_snapshot_json
	;;
health)
	require_auth
	json_hdr
	ui_health_detail_json
	;;
matrix)
	require_auth
	json_hdr
	ui_matrix_json
	;;
lookup)
	require_auth
	json_hdr
	raw=$(urldecode "$(get_arg domain)")
	ui_route_lookup "$raw"
	;;
set)
	require_auth
	layer=$(get_arg layer)
	on=$(norm_bool "$(get_arg on)")
	case "$layer" in
	zapret)
		uci set rvpn.main.zapret_enabled="$on"
		uci commit rvpn
		svc_async restart
		;;
	vpn)
		uci set rvpn.main.vpn_enabled="$on"
		uci commit rvpn
		svc_async restart
		;;
	adblock)
		uci set rvpn.main.adblock_enabled="$on"
		uci commit rvpn
		(
			rvpn_with_lock /bin/sh -c '
				. /usr/lib/rvpn/adblock.sh
				. /usr/lib/rvpn/health.sh
				adblock_apply
				health_cron_install
			' >>"$RVPN_LOG" 2>&1
		) &
		;;
	*)
		text_hdr
		echo "bad layer"
		exit 0
		;;
	esac
	json_hdr
	adb=$(uci_get adblock_enabled)
	adb_dom=0
	[ -f /tmp/rvpn/adblock.meta ] && adb_dom=$(sed -n 's/^domains=//p' /tmp/rvpn/adblock.meta | head -1)
	printf '{"ok":1,"async":1,"zapret_enabled":%s,"vpn_enabled":%s,"adblock_enabled":%s,"adblock_domains":%s,"zapret_running":0,"vpn_running":0}\n' \
		"$(uci_get zapret_enabled)" "$(uci_get vpn_enabled)" "${adb:-0}" "${adb_dom:-0}"
	;;
preset)
	require_auth
	name=$(urldecode "$(get_arg name)")
	json_hdr
	if ui_preset_apply "$name"; then
		svc_async restart
	else
		echo '{"error":"bad_preset"}'
	fi
	;;
stop)
	require_auth
	svc_async stop
	text_hdr
	echo OK
	;;
restart)
	require_auth
	svc_async restart
	text_hdr
	echo OK
	;;
log)
	require_auth
	text_hdr
	tail -n 120 "$RVPN_LOG" 2>/dev/null
	;;
load)
	require_auth
	text_hdr
	health_load_sample 2>/dev/null || true
	echo "# ts load_x100 mem_avail_kb mem_total_kb lan_clients wan_rx wan_tx vpn zap"
	tail -n 48 "$RVPN_LOAD_LOG" 2>/dev/null || echo "(no samples yet)"
	;;
load_json)
	require_auth
	json_hdr
	ui_load_json
	;;
ping)
	require_auth
	json_hdr
	api=$(clash_api_local)
	sec=$(uci_get clash_secret)
	[ -n "$sec" ] || sec=$(ensure_clash_secret)
	ut_url=$(uci_get urltest_url)
	[ -n "$ut_url" ] || ut_url="https://www.gstatic.com/generate_204"
	curl -sS --connect-timeout 2 --max-time 8 \
		-H "Authorization: Bearer $sec" \
		-G "http://${api}/proxies/rvpn-urltest/delay" \
		--data-urlencode "url=${ut_url}" \
		--data "timeout=5000" 2>/dev/null || echo '{"delay":0}'
	;;
domains)
	require_auth
	json_hdr
	ui_domains_json
	;;
add-domain)
	require_auth
	raw=$(urldecode "$(get_arg domain)")
	layer=$(get_arg layer)
	[ -n "$layer" ] || layer=vpn
	json_hdr
	ui_route_add "$layer" "$raw" || echo '{"error":"bad_domain"}'
	;;
del-domain)
	require_auth
	raw=$(urldecode "$(get_arg domain)")
	layer=$(get_arg layer)
	[ -n "$layer" ] || layer=vpn
	d=$(normalize_domain "$raw")
	json_hdr
	if ! valid_domain_token "$d"; then
		echo '{"error":"bad_domain"}'
		exit 0
	fi
	case "$layer" in
	vpn)
		vpn_user_del "$d"
		sb_reload_domains >/dev/null 2>&1 || true
		;;
	zapret|dpi)
		ui_list_del "$RVPN_DPI_USER" "$d" "# User DPI hostlist (quick-add). Merged with dpi.txt." >/dev/null || {
			echo '{"error":"bad_domain"}'
			exit 0
		}
		if [ "$(uci_get zapret_enabled)" = "1" ]; then
			rvpn_with_lock /bin/sh -c '. /usr/lib/rvpn/zapret.sh; zapret_start' >>"$RVPN_LOG" 2>&1 || true
		fi
		;;
	games|direct)
		ui_list_del "$RVPN_GAMES_USER" "$d" "# User games DIRECT (quick-add). Merged with games-domains.txt." >/dev/null || {
			echo '{"error":"bad_domain"}'
			exit 0
		}
		sb_reload_domains >/dev/null 2>&1 || true
		;;
	allow|adblock-allow)
		ui_list_del "$RVPN_ADBLOCK_ALLOW" "$d" "# Allowlist — never block (exact or suffix match)." >/dev/null || {
			echo '{"error":"bad_domain"}'
			exit 0
		}
		if [ "$(uci_get adblock_enabled)" = "1" ]; then
			adblock_apply >/dev/null 2>&1 || true
		fi
		;;
	*)
		echo '{"error":"bad_layer"}'
		exit 0
		;;
	esac
	dj=$(json_escape "$d")
	printf '{"ok":1,"domain":"%s","layer":"%s"}\n' "$dj" "$(json_escape "$layer")"
	;;
adblock-update)
	require_auth
	(
		rvpn_with_lock /bin/sh -c '. /usr/lib/rvpn/adblock.sh; adblock_update' >>"$RVPN_LOG" 2>&1
	) &
	json_hdr
	echo '{"ok":1,"async":1}'
	;;
adblock-allow)
	require_auth
	raw=$(urldecode "$(get_arg domain)")
	json_hdr
	ui_route_add allow "$raw" || echo '{"error":"bad_domain"}'
	;;
cidr-sync)
	require_auth
	(
		rvpn_with_lock /bin/sh -c '. /usr/lib/rvpn/cidr-sync.sh; cidr_sync_run' >>"$RVPN_LOG" 2>&1
	) &
	json_hdr
	echo '{"ok":1,"async":1}'
	;;
subs)
	require_auth
	json_hdr
	ui_subs_json
	;;
sub-set)
	require_auth
	sid=$(urldecode "$(get_arg id)")
	[ -n "$sid" ] || sid=sub1
	json_hdr
	if ! valid_uci_name "$sid"; then
		echo '{"error":"bad_id"}'
		exit 0
	fi
	# Only mutate existing subscription sections — never create/overwrite main/nodes
	if ! uci_is_subscription "$sid"; then
		echo '{"error":"not_subscription"}'
		exit 0
	fi
	url=$(urldecode "$(get_arg url)")
	en=$(get_arg enabled)
	if [ -n "$url" ]; then
		if ! valid_sub_url "$url"; then
			echo '{"error":"bad_url"}'
			exit 0
		fi
		# sid/url validated — safe in double quotes for uci
		uci set "rvpn.${sid}.url=$url"
	fi
	if [ -n "$en" ]; then
		uci set "rvpn.${sid}.enabled=$(norm_bool "$en")"
	fi
	uci commit rvpn
	ui_subs_json
	;;
sub-refresh)
	require_auth
	sid=$(urldecode "$(get_arg id)")
	json_hdr
	if [ -n "$sid" ]; then
		if ! valid_uci_name "$sid" || ! uci_is_subscription "$sid"; then
			echo '{"error":"bad_id"}'
			exit 0
		fi
		# Pass sid as argv — never interpolate into sh -c string
		(
			rvpn_with_lock /bin/sh -c '
				. /usr/lib/rvpn/sub.sh
				sub_refresh "$1"
			' sh "$sid" >>"$RVPN_LOG" 2>&1
		) &
	else
		(
			rvpn_with_lock /bin/sh -c '. /usr/lib/rvpn/sub.sh; sub_refresh_all' >>"$RVPN_LOG" 2>&1
		) &
	fi
	echo '{"ok":1,"async":1}'
	;;
pool)
	require_auth
	json_hdr
	ui_pool_json
	;;
pool-probe)
	require_auth
	(
		rvpn_with_lock /bin/sh -c '. /usr/lib/rvpn/node-pool.sh; pool_probe_all' >>"$RVPN_LOG" 2>&1
	) &
	json_hdr
	echo '{"ok":1,"async":1}'
	;;
pool-optimize)
	require_auth
	(
		rvpn_with_lock /bin/sh -c '
			. /usr/lib/rvpn/node-pool.sh
			. /usr/lib/rvpn/singbox.sh
			if pool_run; then
				sb_reload_domains || /etc/init.d/rvpn restart
			else
				. /usr/lib/rvpn/common.sh
				log "pool-optimize: pool_run failed — skip reload"
				exit 1
			fi
		' >>"$RVPN_LOG" 2>&1
	) &
	json_hdr
	echo '{"ok":1,"async":1}'
	;;
zapret-strat)
	require_auth
	json_hdr
	# shellcheck source=/dev/null
	. /usr/lib/rvpn/zapret-strat.sh
	id=$(urldecode "$(get_arg id)")
	if [ -n "$id" ]; then
		zapret_strat_set "$id" >/dev/null || {
			echo '{"error":"bad_strategy"}'
			exit 0
		}
		if [ "$(uci_get zapret_enabled)" = "1" ]; then
			(
				rvpn_with_lock /bin/sh -c '
					. /usr/lib/rvpn/zapret.sh
					. /usr/lib/rvpn/nft.sh
					zapret_start
					nft_apply_zapret
				' >>"$RVPN_LOG" 2>&1
			) &
		fi
	fi
	zapret_strat_json
	;;
zapret-sync)
	require_auth
	(
		rvpn_with_lock /bin/sh -c '. /usr/lib/rvpn/zapret-sync.sh; zapret_sync_run' >>"$RVPN_LOG" 2>&1
	) &
	json_hdr
	echo '{"ok":1,"async":1}'
	;;
zapret-autotune)
	require_auth
	(
		rvpn_with_lock /bin/sh -c '
			. /usr/lib/rvpn/zapret-test.sh
			zapret_test_autotune
		' >>"$RVPN_LOG" 2>&1
	) &
	json_hdr
	echo '{"ok":1,"async":1}'
	;;
setup)
	require_auth
	json_hdr
	ui_setup_status_json
	;;
setup-done)
	require_auth
	json_hdr
	ui_setup_done_set
	;;
setup-step)
	require_auth
	json_hdr
	step=$(urldecode "$(get_arg step)")
	step=$(printf '%s' "$step" | tr -cd 'A-Za-z0-9_-')
	[ -n "$step" ] || step=start
	printf '%s\n' "$step" >"$RVPN_RUN/setup.state"
	echo '{"ok":1,"step":"'"$step"'"}'
	;;
categories)
	require_auth
	json_hdr
	ui_categories_json
	;;
lists-sync)
	require_auth
	(
		rvpn_with_lock /bin/sh -c '
			. /usr/lib/rvpn/zapret-sync.sh
			. /usr/lib/rvpn/cidr-sync.sh
			. /usr/lib/rvpn/nfqws-fetch.sh
			zapret_sync_run || true
			cidr_sync_run || true
			nfqws_fetch_run || true
		' >>"$RVPN_LOG" 2>&1
	) &
	json_hdr
	echo '{"ok":1,"async":1}'
	;;
selftest)
	require_auth
	json_hdr
	# shellcheck source=/dev/null
	. /usr/lib/rvpn/selftest.sh
	selftest_run
	;;
wifi-qr)
	require_auth
	json_hdr
	ui_wifi_qr_json
	;;
update-check)
	require_auth
	json_hdr
	# shellcheck source=/dev/null
	. /usr/lib/rvpn/update.sh
	update_check_json
	;;
update)
	require_auth
	(
		rvpn_with_lock /bin/sh -c '. /usr/lib/rvpn/update.sh; update_run' >>"$RVPN_LOG" 2>&1
	) &
	json_hdr
	echo '{"ok":1,"async":1}'
	;;
nfqws-fetch)
	require_auth
	(
		rvpn_with_lock /bin/sh -c '. /usr/lib/rvpn/nfqws-fetch.sh; nfqws_fetch_run' >>"$RVPN_LOG" 2>&1
	) &
	json_hdr
	echo '{"ok":1,"async":1}'
	;;
vps-set)
	require_auth
	json_hdr
	server=$(urldecode "$(get_arg server)")
	port=$(get_arg port)
	password=$(urldecode "$(get_arg password)")
	sni=$(urldecode "$(get_arg sni)")
	[ -n "$sni" ] || sni=bing.com
	case "$port" in ''|*[!0-9]*) port=433 ;; esac
	if [ -z "$server" ] || [ -z "$password" ]; then
		echo '{"error":"need_server_password"}'
		exit 0
	fi
	uci set rvpn.vps_hy2=node
	uci set rvpn.vps_hy2.enabled='1'
	uci set rvpn.vps_hy2.tag='vps-hy2'
	uci set rvpn.vps_hy2.type='hysteria2'
	uci set rvpn.vps_hy2.server="$server"
	uci set rvpn.vps_hy2.port="$port"
	uci set rvpn.vps_hy2.password="$password"
	uci set rvpn.vps_hy2.sni="$sni"
	uci set rvpn.vps_hy2.insecure='0'
	uci set rvpn.main.vpn_enabled='1'
	uci commit rvpn
	svc_async restart
	(
		sleep 8
		. /usr/lib/rvpn/zapret-sync.sh
		zapret_after_vpn_ready >>"$RVPN_LOG" 2>&1 || true
	) &
	echo '{"ok":1,"async":1,"vpn_enabled":1}'
	;;
*)
	text_hdr
	echo "unknown"
	;;
esac
