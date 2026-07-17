#!/bin/sh
# DNS: FakeIP upstream when VPN on; filter-aaaa whenever zapret or VPN on.
# Fail-open restore. Prefer reload over restart.

. /usr/lib/rvpn/common.sh

DNS_MARK_FILE=/tmp/rvpn/dns.applied
DNS_BACKUP=/tmp/rvpn/dns.backup
DNS_AAAA_BACKUP=/tmp/rvpn/dns.aaaa.backup

dns_reload() {
	/etc/init.d/dnsmasq reload >/dev/null 2>&1 || \
		killall -HUP dnsmasq >/dev/null 2>&1 || true
}

dns_backup_once() {
	if [ ! -f "$DNS_BACKUP" ]; then
		uci -q get dhcp.@dnsmasq[0].server >"$DNS_BACKUP" 2>/dev/null || true
		uci -q get dhcp.@dnsmasq[0].noresolv >"$DNS_BACKUP.noresolv" 2>/dev/null || true
	fi
	if [ ! -f "$DNS_AAAA_BACKUP" ]; then
		uci -q get dhcp.@dnsmasq[0].filter_aaaa >"$DNS_AAAA_BACKUP" 2>/dev/null || true
	fi
}

dns_apply() {
	zap=$(uci_get zapret_enabled)
	vpn=$(uci_get vpn_enabled)

	if [ "$zap" != "1" ] && [ "$vpn" != "1" ]; then
		dns_restore
		return 0
	fi

	listen=$(uci_get dns_listen)
	[ -n "$listen" ] || listen=127.0.0.42

	dns_backup_once

	# Kill IPv6 answers so LAN cannot skip nfqws/FakeIP via AAAA
	uci set dhcp.@dnsmasq[0].filter_aaaa='1'

	if [ "$vpn" = "1" ]; then
		uci -q delete dhcp.@dnsmasq[0].server
		uci add_list dhcp.@dnsmasq[0].server="$listen"
		uci set dhcp.@dnsmasq[0].noresolv='1'
		uci set dhcp.@dnsmasq[0].localuse='1'
		log "dns applied → FakeIP $listen + filter_aaaa"
	else
		# zapret-only: keep normal upstream, only filter AAAA
		if [ -f "$DNS_MARK_FILE" ] && grep -q fakeip "$DNS_MARK_FILE" 2>/dev/null; then
			uci -q delete dhcp.@dnsmasq[0].server
			if [ -s "$DNS_BACKUP" ]; then
				while read -r s; do
					[ -n "$s" ] && uci add_list dhcp.@dnsmasq[0].server="$s"
				done <"$DNS_BACKUP"
			fi
			uci -q delete dhcp.@dnsmasq[0].noresolv
		fi
		log "dns applied → filter_aaaa (zapret-only)"
	fi

	uci commit dhcp
	dns_reload
	if [ "$vpn" = "1" ]; then
		echo fakeip >"$DNS_MARK_FILE"
	else
		echo aaaa >"$DNS_MARK_FILE"
	fi
}

dns_restore() {
	[ -f "$DNS_MARK_FILE" ] || [ -f "$DNS_BACKUP" ] || [ -f "$DNS_AAAA_BACKUP" ] || return 0

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

	if [ -f "$DNS_AAAA_BACKUP" ]; then
		aa=$(cat "$DNS_AAAA_BACKUP" 2>/dev/null)
		if [ -n "$aa" ]; then
			uci set dhcp.@dnsmasq[0].filter_aaaa="$aa"
		else
			uci -q delete dhcp.@dnsmasq[0].filter_aaaa
		fi
	else
		uci -q delete dhcp.@dnsmasq[0].filter_aaaa
	fi

	uci commit dhcp
	dns_reload
	rm -f "$DNS_MARK_FILE" "$DNS_BACKUP" "$DNS_BACKUP.noresolv" "$DNS_AAAA_BACKUP"
	log "dns restored"
}
