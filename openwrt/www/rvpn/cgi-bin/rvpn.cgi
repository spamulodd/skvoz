#!/bin/sh
. /usr/lib/rvpn/common.sh
. /usr/lib/rvpn/health.sh

qs=${QUERY_STRING:-status}
cmd=${qs%%&*}

get_arg() {
	echo "$qs" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1
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
	# Prefer header only (avoid token in access logs). Query token accepted as legacy.
	got=$HTTP_X_SKVOZ_TOKEN
	[ -z "$got" ] && got=$(get_arg token)
	if [ -z "$got" ] || [ "$got" != "$want" ]; then
		echo "Status: 401 Unauthorized"
		json_hdr
		echo '{"error":"unauthorized"}'
		exit 0
	fi
}

# Async service action under flock
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
	zapret) uci set rvpn.main.zapret_enabled="$on" ;;
	vpn) uci set rvpn.main.vpn_enabled="$on" ;;
	*)
		text_hdr
		echo "bad layer"
		exit 0
		;;
	esac
	uci commit rvpn
	svc_async restart
	json_hdr
	# Include enabled flags; running updates after async restart (UI polls).
	printf '{"ok":1,"async":1,"zapret_enabled":%s,"vpn_enabled":%s,"zapret_running":0,"vpn_running":0}\n' \
		"$(uci_get zapret_enabled)" "$(uci_get vpn_enabled)"
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
*)
	text_hdr
	echo "unknown"
	;;
esac
