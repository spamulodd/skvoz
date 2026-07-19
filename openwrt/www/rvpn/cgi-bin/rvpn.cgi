#!/bin/sh
. /usr/lib/rvpn/common.sh
. /usr/lib/rvpn/health.sh
. /usr/lib/rvpn/singbox.sh
. /usr/lib/rvpn/adblock.sh

qs=${QUERY_STRING:-status}
cmd=${qs%%&*}

get_arg() {
	echo "$qs" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1 | sed 's/+/ /g' | sed 's/%3A/:/g;s/%2F/\//g;s/%3a/:/g;s/%2f/\//g'
}

# Minimal URL-decode for domain args
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
	# uhttpd often does NOT pass custom headers/cookies to CGI — query token is reliable.
	got=$(get_arg token)
	[ -z "$got" ] && got=$HTTP_X_SKVOZ_TOKEN
	if [ -z "$got" ] && [ -n "$HTTP_COOKIE" ]; then
		got=$(echo "$HTTP_COOKIE" | tr ';' '\n' | sed -n 's/^[[:space:]]*skvoz_token=//p' | head -1)
	fi
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
			rvpn_with_lock /bin/sh -c '. /usr/lib/rvpn/adblock.sh; . /usr/lib/rvpn/health.sh; adblock_apply; health_cron_install' >>"$RVPN_LOG" 2>&1
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
	tmpu=$RVPN_RUN/domains-user.jsonl
	: >"$tmpu"
	list_domains "$RVPN_USER_DOMAINS" 2>/dev/null | while IFS= read -r d; do
		[ -n "$d" ] || continue
		printf '"%s"\n' "$(json_escape "$d")" >>"$tmpu"
	done
	echo -n '{"user":['
	sep=
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		printf '%s%s' "$sep" "$line"
		sep=,
	done <"$tmpu"
	echo -n '],"shipped_geo":["atsu.moe","hentailib.me","slashlib.me","v2.shlib.life","mangalib.me","ranobelib.me","lib.social"]}'
	echo
	;;
add-domain)
	require_auth
	raw=$(get_arg domain)
	raw=$(urldecode "$raw")
	if vpn_user_add "$raw"; then
		d=$(normalize_domain "$raw")
		sb_reload_domains >/dev/null 2>&1 || true
		json_hdr
		dj=$(json_escape "$d")
		printf '{"ok":1,"domain":"%s"}\n' "$dj"
	else
		echo "Status: 400 Bad Request"
		json_hdr
		echo '{"error":"bad_domain"}'
	fi
	;;
del-domain)
	require_auth
	raw=$(get_arg domain)
	raw=$(urldecode "$raw")
	d=$(normalize_domain "$raw")
	vpn_user_del "$d"
	sb_reload_domains >/dev/null 2>&1 || true
	json_hdr
	dj=$(json_escape "$d")
	printf '{"ok":1,"domain":"%s"}\n' "$dj"
	;;
*)
	text_hdr
	echo "unknown"
	;;
esac
