# Skvoz post-install configuration (OpenWrt). Idempotent.
# Sourced by tools/install.sh and embedded in .ipk postinst.

skvoz_lan_listen() {
	ip=$(uci -q get network.lan.ipaddr 2>/dev/null)
	ip=${ip%%/*}
	case "$ip" in
	*[!0-9.]*|'') ip=192.168.1.1 ;;
	esac
	echo "${ip}:81"
}

skvoz_postinst() {
	if [ -n "${IPKG_INSTROOT:-}" ]; then
		return 0
	fi

	chmod +x /etc/init.d/rvpn /usr/bin/rvpnctl /www/rvpn/cgi-bin/rvpn.cgi 2>/dev/null || true
	chmod +x /usr/lib/rvpn/*.sh 2>/dev/null || true
	mkdir -p /opt/rvpn /tmp/rvpn /usr/share/rvpn
	chmod 700 /tmp/rvpn 2>/dev/null || true

	listen=$(skvoz_lan_listen)

	uci -q delete uhttpd.rvpn
	uci set uhttpd.rvpn=uhttpd
	uci set uhttpd.rvpn.listen_http="$listen"
	uci set uhttpd.rvpn.home='/www/rvpn'
	uci set uhttpd.rvpn.cgi_prefix='/cgi-bin'
	uci set uhttpd.rvpn.script_timeout='180'
	uci set uhttpd.rvpn.network_timeout='60'
	uci set uhttpd.rvpn.tcp_keepalive='1'
	uci set uhttpd.rvpn.rfc1918_filter='1'
	uci set uhttpd.rvpn.max_requests='40'
	uci commit uhttpd

	if [ -f /usr/lib/rvpn/common.sh ]; then
		# shellcheck disable=SC1091
		. /usr/lib/rvpn/common.sh
		ensure_ui_secret >/dev/null 2>&1 || true
		ensure_clash_secret >/dev/null 2>&1 || true
	fi
	# Fresh install: wizard not done (do not reset on upgrade if already 1)
	cur=$(uci -q get rvpn.main.setup_done 2>/dev/null || echo "")
	case "$cur" in
	1) ;;
	*) uci set rvpn.main.setup_done='0' ;;
	esac
	uci -q get rvpn.main.zapret_strategy >/dev/null 2>&1 || uci set rvpn.main.zapret_strategy='general_alt11'
	uci commit rvpn

	/etc/init.d/uhttpd restart 2>/dev/null || true
	/etc/init.d/rvpn enable
	if [ -f /usr/lib/rvpn/health.sh ]; then
		# shellcheck disable=SC1091
		. /usr/lib/rvpn/common.sh
		. /usr/lib/rvpn/health.sh
		health_cron_install 2>/dev/null || true
	fi
	/etc/init.d/rvpn stop 2>/dev/null || true

	if [ -f /usr/lib/rvpn/zapret-sync.sh ]; then
		# shellcheck disable=SC1091
		. /usr/lib/rvpn/zapret-sync.sh
		if ! zapret_bootstrap_first_install; then
			echo "WARN: Flowseal/GitHub недоступен. Списки — после VPN." >&2
			logger -t rvpn "Flowseal sync pending — after VPN: rvpnctl zapret-sync"
		fi
	fi
	if [ -f /usr/lib/rvpn/nfqws-fetch.sh ]; then
		# shellcheck disable=SC1091
		. /usr/lib/rvpn/nfqws-fetch.sh
		nfqws_fetch_run || {
			echo "WARN: nfqws не скачан (GitHub?). После VPN: rvpnctl nfqws-fetch" >&2
			logger -t rvpn "nfqws fetch pending"
		}
	fi
}
