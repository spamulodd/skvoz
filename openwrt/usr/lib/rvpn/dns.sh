#!/bin/sh
# DNS: FakeIP upstream when VPN on AND sing-box alive; filter-aaaa for zapret/VPN.
# Fail-open: never point dnsmasq at FakeIP while sing-box is dead.

. /usr/lib/rvpn/common.sh

DNS_MARK_FILE=/tmp/rvpn/dns.applied
DNS_BACKUP=/tmp/rvpn/dns.backup
DNS_AAAA_BACKUP=/tmp/rvpn/dns.aaaa.backup
DNS_LOCALUSE_BACKUP=/tmp/rvpn/dns.localuse.backup

dns_reload() {
	/etc/init.d/dnsmasq reload >/dev/null 2>&1 || \
		killall -HUP dnsmasq >/dev/null 2>&1 || true
}

# One upstream per line (uci list may be space-separated on one line).
dns_write_server_backup() {
	: >"$DNS_BACKUP"
	i=0
	while s=$(uci -q get "dhcp.@dnsmasq[0].server[$i]"); do
		[ -n "$s" ] && printf '%s\n' "$s" >>"$DNS_BACKUP"
		i=$((i + 1))
	done
	if [ ! -s "$DNS_BACKUP" ]; then
		# shellcheck disable=SC2046
		for s in $(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null); do
			[ -n "$s" ] && printf '%s\n' "$s" >>"$DNS_BACKUP"
		done
	fi
}

dns_restore_servers_from_backup() {
	uci -q delete dhcp.@dnsmasq[0].server
	if [ -s "$DNS_BACKUP" ]; then
		while IFS= read -r s || [ -n "$s" ]; do
			[ -n "$s" ] || continue
			# split accidental space-joined backups
			for one in $s; do
				uci add_list dhcp.@dnsmasq[0].server="$one"
			done
		done <"$DNS_BACKUP"
	fi
}

dns_backup_once() {
	if [ ! -f "$DNS_BACKUP" ]; then
		dns_write_server_backup
		uci -q get dhcp.@dnsmasq[0].noresolv >"$DNS_BACKUP.noresolv" 2>/dev/null || true
	fi
	if [ ! -f "$DNS_AAAA_BACKUP" ]; then
		uci -q get dhcp.@dnsmasq[0].filter_aaaa >"$DNS_AAAA_BACKUP" 2>/dev/null || true
	fi
	if [ ! -f "$DNS_LOCALUSE_BACKUP" ]; then
		uci -q get dhcp.@dnsmasq[0].localuse >"$DNS_LOCALUSE_BACKUP" 2>/dev/null || true
	fi
}

# True when FakeIP hijack is safe (VPN wanted and sing-box answering).
dns_vpn_ready() {
	vpn=$(uci_get vpn_enabled)
	[ "$vpn" = "1" ] || return 1
	[ -n "$(sb_pids)" ] || return 1
	return 0
}

dns_apply_aaaa_only() {
	dns_backup_once
	uci set dhcp.@dnsmasq[0].filter_aaaa='1'
	# Drop FakeIP upstream if it was active
	if [ -f "$DNS_MARK_FILE" ] && grep -q fakeip "$DNS_MARK_FILE" 2>/dev/null; then
		dns_restore_servers_from_backup
		uci -q delete dhcp.@dnsmasq[0].noresolv
		if [ -f "$DNS_LOCALUSE_BACKUP" ]; then
			lu=$(cat "$DNS_LOCALUSE_BACKUP" 2>/dev/null)
			if [ -n "$lu" ]; then
				uci set dhcp.@dnsmasq[0].localuse="$lu"
			else
				uci -q delete dhcp.@dnsmasq[0].localuse
			fi
		else
			uci -q delete dhcp.@dnsmasq[0].localuse
		fi
	fi
	uci commit dhcp
	dns_reload
	echo aaaa >"$DNS_MARK_FILE"
	log "dns applied → filter_aaaa (no FakeIP)"
}

dns_apply() {
	zap=$(uci_get zapret_enabled)
	vpn=$(uci_get vpn_enabled)

	if [ "$zap" != "1" ] && [ "$vpn" != "1" ]; then
		dns_restore
		return 0
	fi

	# VPN enabled but sing-box down → never hijack DNS (real fail-open)
	if [ "$vpn" = "1" ] && ! dns_vpn_ready; then
		log "dns: vpn_enabled but sing-box down — aaaa-only fail-open"
		dns_apply_aaaa_only
		return 0
	fi

	listen=$(uci_get dns_listen)
	[ -n "$listen" ] || listen=127.0.0.42

	dns_backup_once
	uci set dhcp.@dnsmasq[0].filter_aaaa='1'

	if dns_vpn_ready; then
		uci -q delete dhcp.@dnsmasq[0].server
		uci add_list dhcp.@dnsmasq[0].server="$listen"
		uci set dhcp.@dnsmasq[0].noresolv='1'
		uci set dhcp.@dnsmasq[0].localuse='1'
		uci commit dhcp
		dns_reload
		echo fakeip >"$DNS_MARK_FILE"
		log "dns applied → FakeIP $listen + filter_aaaa"
	else
		dns_apply_aaaa_only
	fi
}

dns_restore() {
	[ -f "$DNS_MARK_FILE" ] || [ -f "$DNS_BACKUP" ] || [ -f "$DNS_AAAA_BACKUP" ] || \
		[ -f "$DNS_LOCALUSE_BACKUP" ] || return 0

	dns_restore_servers_from_backup

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

	if [ -f "$DNS_LOCALUSE_BACKUP" ]; then
		lu=$(cat "$DNS_LOCALUSE_BACKUP" 2>/dev/null)
		if [ -n "$lu" ]; then
			uci set dhcp.@dnsmasq[0].localuse="$lu"
		else
			uci -q delete dhcp.@dnsmasq[0].localuse
		fi
	fi

	uci commit dhcp
	dns_reload
	rm -f "$DNS_MARK_FILE" "$DNS_BACKUP" "$DNS_BACKUP.noresolv" \
		"$DNS_AAAA_BACKUP" "$DNS_LOCALUSE_BACKUP"
	log "dns restored"
}
