#!/bin/sh
# Content-Type: text/plain or application/json

. /usr/lib/rvpn/common.sh
. /usr/lib/rvpn/health.sh

qs=${QUERY_STRING:-status}
cmd=${qs%%&*}

get_arg() {
	echo "$qs" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1
}

json_hdr() {
	echo "Content-Type: application/json; charset=utf-8"
	echo "Access-Control-Allow-Origin: *"
	echo ""
}

text_hdr() {
	echo "Content-Type: text/plain; charset=utf-8"
	echo "Access-Control-Allow-Origin: *"
	echo ""
}

case "$cmd" in
status)
	json_hdr
	health_status_json
	;;
set)
	layer=$(get_arg layer)
	on=$(get_arg on)
	case "$layer" in
	zapret)
		uci set rvpn.main.zapret_enabled="${on:-0}"
		;;
	vpn)
		uci set rvpn.main.vpn_enabled="${on:-0}"
		;;
	*)
		text_hdr
		echo "bad layer"
		exit 0
		;;
	esac
	uci commit rvpn
	/etc/init.d/rvpn restart
	json_hdr
	health_status_json
	;;
stop)
	text_hdr
	/etc/init.d/rvpn stop
	echo OK
	;;
restart)
	text_hdr
	/etc/init.d/rvpn restart
	echo OK
	;;
log)
	text_hdr
	tail -n 120 "$RVPN_LOG" 2>/dev/null
	;;
ping)
	json_hdr
	api=$(uci_get clash_api)
	[ -n "$api" ] || api="127.0.0.1:9090"
	ut_url=$(uci_get urltest_url)
	[ -n "$ut_url" ] || ut_url="https://www.gstatic.com/generate_204"
	curl -sS --connect-timeout 2 --max-time 8 \
		-G "http://${api}/proxies/rvpn-urltest/delay" \
		--data-urlencode "url=${ut_url}" \
		--data "timeout=5000" 2>/dev/null || echo '{"delay":0}'
	;;
*)
	text_hdr
	echo "unknown"
	;;
esac
