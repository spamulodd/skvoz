# Skvoz post-install configuration (OpenWrt). Idempotent.
# Sourced by tools/install.sh and embedded in .ipk postinst.

skvoz_postinst() {
	# Skip during image/rootfs staging
	if [ -n "${IPKG_INSTROOT:-}" ]; then
		return 0
	fi

	chmod +x /etc/init.d/rvpn /usr/bin/rvpnctl /www/rvpn/cgi-bin/rvpn.cgi 2>/dev/null || true
	chmod +x /usr/lib/rvpn/*.sh 2>/dev/null || true
	mkdir -p /opt/rvpn /tmp/rvpn

	# uhttpd instance for UI on :81
	uci -q delete uhttpd.rvpn
	uci set uhttpd.rvpn=uhttpd
	uci set uhttpd.rvpn.listen_http='0.0.0.0:81'
	uci set uhttpd.rvpn.home='/www/rvpn'
	uci set uhttpd.rvpn.cgi_prefix='/cgi-bin'
	uci set uhttpd.rvpn.script_timeout='120'
	uci set uhttpd.rvpn.network_timeout='60'
	uci set uhttpd.rvpn.tcp_keepalive='1'
	uci set uhttpd.rvpn.rfc1918_filter='0'
	uci set uhttpd.rvpn.max_requests='40'
	uci commit uhttpd

	# Safety: layers OFF on fresh install
	uci set rvpn.main.zapret_enabled='0'
	uci set rvpn.main.vpn_enabled='0'

	if [ -f /usr/lib/rvpn/common.sh ]; then
		# shellcheck disable=SC1091
		. /usr/lib/rvpn/common.sh
		ensure_ui_secret >/dev/null 2>&1 || true
	fi
	uci commit rvpn

	/etc/init.d/uhttpd restart 2>/dev/null || true
	/etc/init.d/rvpn enable
	/etc/init.d/rvpn stop 2>/dev/null || true
}
