# Skvoz post-install configuration (OpenWrt). Idempotent.
# Sourced by tools/install.sh and embedded in .ipk postinst.

skvoz_lan_listen() {
	ip=$(uci -q get network.lan.ipaddr 2>/dev/null)
	# strip CIDR if present
	ip=${ip%%/*}
	case "$ip" in
	*[!0-9.]*|'') ip=192.168.1.1 ;;
	esac
	echo "${ip}:81"
}

skvoz_postinst() {
	# Skip during image/rootfs staging
	if [ -n "${IPKG_INSTROOT:-}" ]; then
		return 0
	fi

	chmod +x /etc/init.d/rvpn /usr/bin/rvpnctl /www/rvpn/cgi-bin/rvpn.cgi 2>/dev/null || true
	chmod +x /usr/lib/rvpn/*.sh 2>/dev/null || true
	mkdir -p /opt/rvpn /tmp/rvpn
	chmod 700 /tmp/rvpn 2>/dev/null || true

	listen=$(skvoz_lan_listen)

	# uhttpd UI — LAN only, rfc1918 filter on
	uci -q delete uhttpd.rvpn
	uci set uhttpd.rvpn=uhttpd
	uci set uhttpd.rvpn.listen_http="$listen"
	uci set uhttpd.rvpn.home='/www/rvpn'
	uci set uhttpd.rvpn.cgi_prefix='/cgi-bin'
	uci set uhttpd.rvpn.script_timeout='120'
	uci set uhttpd.rvpn.network_timeout='60'
	uci set uhttpd.rvpn.tcp_keepalive='1'
	uci set uhttpd.rvpn.rfc1918_filter='1'
	uci set uhttpd.rvpn.max_requests='40'
	uci commit uhttpd

	# Do NOT force layers OFF on upgrade — defaults live in /etc/config/rvpn
	# Only generate secrets if missing
	if [ -f /usr/lib/rvpn/common.sh ]; then
		# shellcheck disable=SC1091
		. /usr/lib/rvpn/common.sh
		ensure_ui_secret >/dev/null 2>&1 || true
		ensure_clash_secret >/dev/null 2>&1 || true
	fi
	uci commit rvpn

	/etc/init.d/uhttpd restart 2>/dev/null || true
	/etc/init.d/rvpn enable
	# Hourly load samples for stress/ops (idempotent)
	if [ -f /usr/lib/rvpn/health.sh ]; then
		# shellcheck disable=SC1091
		. /usr/lib/rvpn/common.sh
		. /usr/lib/rvpn/health.sh
		health_cron_install 2>/dev/null || true
	fi
	# Fresh install marker: if layers never configured, leave config defaults (off)
	/etc/init.d/rvpn stop 2>/dev/null || true
}
