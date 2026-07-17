#!/bin/sh
# DNS: when VPN on, dnsmasq upstream → sing-box FakeIP listener.
# Fail-open: restore always removes our overrides. Prefer reload over restart.

. /usr/lib/rvpn/common.sh

DNS_MARK_FILE=/tmp/rvpn/dns.applied
DNS_BACKUP=/tmp/rvpn/dns.backup

dns_reload() {
	# avoid hanging full restart
	/etc/init.d/dnsmasq reload >/dev/null 2>&1 || \
		killall -HUP dnsmasq >/dev/null 2>&1 || true
}

dns_apply() {
	vpn=$(uci_get vpn_enabled)
	[ "$vpn" = "1" ] || { dns_restore; return 0; }

	listen=$(uci_get dns_listen)
	[ -n "$listen" ] || listen=127.0.0.42

	if [ ! -f "$DNS_BACKUP" ]; then
		uci -q get dhcp.@dnsmasq[0].server >"$DNS_BACKUP" 2>/dev/null || true
		uci -q get dhcp.@dnsmasq[0].noresolv >"$DNS_BACKUP.noresolv" 2>/dev/null || true
	fi

	uci -q delete dhcp.@dnsmasq[0].server
	uci add_list dhcp.@dnsmasq[0].server="$listen"
	uci set dhcp.@dnsmasq[0].noresolv='1'
	uci set dhcp.@dnsmasq[0].localuse='1'
	uci commit dhcp
	dns_reload
	echo 1 >"$DNS_MARK_FILE"
	log "dns applied → $listen"
}

dns_restore() {
	[ -f "$DNS_MARK_FILE" ] || [ -f "$DNS_BACKUP" ] || return 0

	uci -q delete dhcp.@dnsmasq[0].server
	if [ -s "$DNS_BACKUP" ]; then
		while read -r s; do
			[ -n "$s" ] && uci add_list dhcp.@dnsmasq[0].server="$s"
		done <"$DNS_BACKUP"
	fi
	if [ -f "$DNS_BACKUP.noresolv" ]; then
		nr=$(cat "$DNS_BACKUP.noresolv" 2>/dev/null)
		if [ -n "$nr" ]; then
			uci set dhcp.@dnsmasq[0].noresolv="$nr"
		else
			uci -q delete dhcp.@dnsmasq[0].noresolv
		fi
	else
		uci -q delete dhcp.@dnsmasq[0].noresolv
	fi
	uci commit dhcp
	dns_reload
	rm -f "$DNS_MARK_FILE" "$DNS_BACKUP" "$DNS_BACKUP.noresolv"
	log "dns restored"
}
