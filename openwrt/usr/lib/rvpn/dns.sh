#!/bin/sh
# DNS: FakeIP upstream when VPN on AND sing-box alive; filter-aaaa for zapret/VPN.
# Fail-open: never point dnsmasq at FakeIP while sing-box is dead.
# Critical: UCI dhcp survives reboot, /tmp backups do not — always heal orphans.

. /usr/lib/rvpn/common.sh

DNS_MARK_FILE=/tmp/rvpn/dns.applied
DNS_BACKUP=/tmp/rvpn/dns.backup
DNS_AAAA_BACKUP=/tmp/rvpn/dns.aaaa.backup
DNS_LOCALUSE_BACKUP=/tmp/rvpn/dns.localuse.backup
# Persistent copy — /tmp is wiped on reboot; FakeIP in UCI must not lose the real upstream.
DNS_PERSIST_DIR=/etc/rvpn/dns-backup

dns_reload() {
	/etc/init.d/dnsmasq reload >/dev/null 2>&1 || \
		killall -HUP dnsmasq >/dev/null 2>&1 || true
}

dns_listen_addr() {
	listen=$(uci_get dns_listen)
	[ -n "$listen" ] || listen=127.0.0.42
	echo "$listen"
}

# True when dnsmasq upstream is the FakeIP listener (sing-box).
dns_uci_points_to_fakeip() {
	listen=$(dns_listen_addr)
	srv=$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null || true)
	case "$srv" in
	*"$listen"*) return 0 ;;
	esac
	return 1
}

dns_backup_file_sane() {
	f=$1
	[ -f "$f" ] || return 1
	listen=$(dns_listen_addr)
	# Empty backup is ok (means "no custom servers" / use resolv.conf)
	grep -Fq "$listen" "$f" 2>/dev/null && return 1
	return 0
}

dns_persist_load_to_tmp() {
	mkdir -p "$RVPN_RUN" "$DNS_PERSIST_DIR" 2>/dev/null || true
	if [ ! -f "$DNS_BACKUP" ] && dns_backup_file_sane "$DNS_PERSIST_DIR/server"; then
		cp -f "$DNS_PERSIST_DIR/server" "$DNS_BACKUP" 2>/dev/null || true
		[ -f "$DNS_PERSIST_DIR/noresolv" ] && cp -f "$DNS_PERSIST_DIR/noresolv" "$DNS_BACKUP.noresolv" 2>/dev/null || true
		[ -f "$DNS_PERSIST_DIR/aaaa" ] && cp -f "$DNS_PERSIST_DIR/aaaa" "$DNS_AAAA_BACKUP" 2>/dev/null || true
		[ -f "$DNS_PERSIST_DIR/localuse" ] && cp -f "$DNS_PERSIST_DIR/localuse" "$DNS_LOCALUSE_BACKUP" 2>/dev/null || true
	fi
}

dns_persist_save_from_tmp() {
	mkdir -p "$DNS_PERSIST_DIR" 2>/dev/null || true
	dns_backup_file_sane "$DNS_BACKUP" || return 1
	cp -f "$DNS_BACKUP" "$DNS_PERSIST_DIR/server" 2>/dev/null || true
	[ -f "$DNS_BACKUP.noresolv" ] && cp -f "$DNS_BACKUP.noresolv" "$DNS_PERSIST_DIR/noresolv" 2>/dev/null || true
	[ -f "$DNS_AAAA_BACKUP" ] && cp -f "$DNS_AAAA_BACKUP" "$DNS_PERSIST_DIR/aaaa" 2>/dev/null || true
	[ -f "$DNS_LOCALUSE_BACKUP" ] && cp -f "$DNS_LOCALUSE_BACKUP" "$DNS_PERSIST_DIR/localuse" 2>/dev/null || true
	return 0
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
			for one in $s; do
				uci add_list dhcp.@dnsmasq[0].server="$one"
			done
		done <"$DNS_BACKUP"
	fi
}

dns_backup_once() {
	mkdir -p "$RVPN_RUN" "$DNS_PERSIST_DIR" 2>/dev/null || true
	dns_persist_load_to_tmp

	# Already have a sane backup — keep it (never overwrite with FakeIP).
	if dns_backup_file_sane "$DNS_BACKUP"; then
		dns_persist_save_from_tmp || true
		[ -f "$DNS_AAAA_BACKUP" ] || {
			uci -q get dhcp.@dnsmasq[0].filter_aaaa >"$DNS_AAAA_BACKUP" 2>/dev/null || true
		}
		[ -f "$DNS_LOCALUSE_BACKUP" ] || {
			uci -q get dhcp.@dnsmasq[0].localuse >"$DNS_LOCALUSE_BACKUP" 2>/dev/null || true
		}
		return 0
	fi

	# Never snapshot FakeIP upstream as "original" — that poisons restore forever.
	if dns_uci_points_to_fakeip; then
		log "dns backup skipped — UCI already FakeIP (no sane original)"
		return 0
	fi

	dns_write_server_backup
	uci -q get dhcp.@dnsmasq[0].noresolv >"$DNS_BACKUP.noresolv" 2>/dev/null || true
	if [ ! -f "$DNS_AAAA_BACKUP" ]; then
		uci -q get dhcp.@dnsmasq[0].filter_aaaa >"$DNS_AAAA_BACKUP" 2>/dev/null || true
	fi
	if [ ! -f "$DNS_LOCALUSE_BACKUP" ]; then
		uci -q get dhcp.@dnsmasq[0].localuse >"$DNS_LOCALUSE_BACKUP" 2>/dev/null || true
	fi
	dns_persist_save_from_tmp || true
}

# Strip FakeIP upstream; restore real servers or fall back to ISP resolv.conf.
dns_clear_fakeip_upstream() {
	dns_persist_load_to_tmp
	if dns_backup_file_sane "$DNS_BACKUP"; then
		dns_restore_servers_from_backup
	else
		uci -q delete dhcp.@dnsmasq[0].server
	fi
	# If no custom upstream servers, never leave noresolv=1 (REFUSED / blackhole)
	srv_left=$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null || true)
	if [ -z "$srv_left" ]; then
		uci -q delete dhcp.@dnsmasq[0].noresolv
	elif [ -f "$DNS_BACKUP.noresolv" ]; then
		nr=$(cat "$DNS_BACKUP.noresolv" 2>/dev/null)
		# Ignore poisoned backup that still says noresolv=1 from FakeIP era
		if [ "$nr" = "1" ]; then
			uci -q delete dhcp.@dnsmasq[0].noresolv
		elif [ -n "$nr" ]; then
			uci set dhcp.@dnsmasq[0].noresolv="$nr"
		else
			uci -q delete dhcp.@dnsmasq[0].noresolv
		fi
	else
		uci -q delete dhcp.@dnsmasq[0].noresolv
	fi
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
}

dns_vpn_ready() {
	vpn=$(uci_get vpn_enabled)
	[ "$vpn" = "1" ] || return 1
	sb_alive || return 1
	return 0
}

# Desired mark: off | aaaa | fakeip
dns_desired_mark() {
	zap=$(uci_get zapret_enabled)
	vpn=$(uci_get vpn_enabled)
	if [ "$zap" != "1" ] && [ "$vpn" != "1" ]; then
		echo off
		return 0
	fi
	if [ "$vpn" = "1" ] && dns_vpn_ready; then
		echo fakeip
		return 0
	fi
	echo aaaa
}

# Boot / start / failsafe: if UCI still has FakeIP but sing-box is not ready — fix NOW.
# Without this, reboot leaves LAN with DNS → 127.0.0.42 and no internet until VPN is up.
dns_heal_orphan() {
	mkdir -p "$RVPN_RUN" 2>/dev/null || true
	dns_persist_load_to_tmp
	if ! dns_uci_points_to_fakeip; then
		return 0
	fi
	if dns_vpn_ready; then
		echo fakeip >"$DNS_MARK_FILE"
		return 0
	fi
	log "dns heal: FakeIP orphan (sing-box not ready) — restoring upstream"
	dns_clear_fakeip_upstream
	# Keep filter_aaaa if zapret/vpn still intended; full restore handles "off"
	zap=$(uci_get zapret_enabled)
	vpn=$(uci_get vpn_enabled)
	if [ "$zap" = "1" ] || [ "$vpn" = "1" ]; then
		uci set dhcp.@dnsmasq[0].filter_aaaa='1'
		uci commit dhcp
		dns_reload
		echo aaaa >"$DNS_MARK_FILE"
	else
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
		rm -f "$DNS_MARK_FILE"
	fi
	log "dns heal done"
	return 0
}

dns_apply_aaaa_only() {
	cur=$(cat "$DNS_MARK_FILE" 2>/dev/null || echo "")
	# Always strip FakeIP if present (reboot / poisoned mark)
	if dns_uci_points_to_fakeip; then
		:
	elif [ "$cur" = "aaaa" ]; then
		return 0
	fi
	dns_backup_once
	uci set dhcp.@dnsmasq[0].filter_aaaa='1'
	if dns_uci_points_to_fakeip || { [ -f "$DNS_MARK_FILE" ] && grep -q fakeip "$DNS_MARK_FILE" 2>/dev/null; }; then
		dns_clear_fakeip_upstream
	fi
	uci commit dhcp
	dns_reload
	echo aaaa >"$DNS_MARK_FILE"
	log "dns applied → filter_aaaa (no FakeIP)"
}

dns_apply() {
	want=$(dns_desired_mark)
	cur=$(cat "$DNS_MARK_FILE" 2>/dev/null || echo "")

	if [ "$want" = "off" ]; then
		dns_restore
		return 0
	fi

	if [ "$want" = "aaaa" ]; then
		dns_apply_aaaa_only
		return 0
	fi

	# want=fakeip
	listen=$(dns_listen_addr)
	if [ "$cur" = "fakeip" ]; then
		srv=$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null || true)
		case "$srv" in
		*"$listen"*)
			# Already FakeIP — no commit/reload
			return 0
			;;
		esac
	fi

	dns_backup_once
	uci set dhcp.@dnsmasq[0].filter_aaaa='1'
	uci -q delete dhcp.@dnsmasq[0].server
	uci add_list dhcp.@dnsmasq[0].server="$listen"
	uci set dhcp.@dnsmasq[0].noresolv='1'
	uci set dhcp.@dnsmasq[0].localuse='1'
	uci commit dhcp
	dns_reload
	echo fakeip >"$DNS_MARK_FILE"
	log "dns applied → FakeIP $listen + filter_aaaa"
}

# True when router DNS answers a simple A query (LAN path).
dns_lan_resolve_ok() {
	if command -v nslookup >/dev/null 2>&1; then
		nslookup openwrt.org 127.0.0.1 >/dev/null 2>&1 && return 0
		nslookup ya.ru 127.0.0.1 >/dev/null 2>&1 && return 0
	fi
	if command -v resolveip >/dev/null 2>&1; then
		resolveip -t 3 openwrt.org >/dev/null 2>&1 && return 0
		resolveip -t 3 ya.ru >/dev/null 2>&1 && return 0
	fi
	# No resolver tool — do not claim failure
	return 0
}

# Flush dnsmasq cache only (no UCI) — for domain list reloads.
dns_flush_cache() {
	killall -HUP dnsmasq 2>/dev/null || true
}

dns_restore() {
	dns_persist_load_to_tmp
	# Nothing to do if clean and no FakeIP leftover
	if [ ! -f "$DNS_MARK_FILE" ] && [ ! -f "$DNS_BACKUP" ] && [ ! -f "$DNS_AAAA_BACKUP" ] && \
		[ ! -f "$DNS_LOCALUSE_BACKUP" ] && ! dns_uci_points_to_fakeip; then
		return 0
	fi

	if dns_uci_points_to_fakeip || [ -f "$DNS_MARK_FILE" ] || [ -f "$DNS_BACKUP" ]; then
		dns_clear_fakeip_upstream
	fi

	if [ -f "$DNS_AAAA_BACKUP" ]; then
		aa=$(cat "$DNS_AAAA_BACKUP" 2>/dev/null)
		if [ -n "$aa" ]; then
			uci set dhcp.@dnsmasq[0].filter_aaaa="$aa"
		else
			uci -q delete dhcp.@dnsmasq[0].filter_aaaa
		fi
	else
		# If we were in FakeIP/aaaa without backup, drop filter_aaaa for fail-open
		if [ -f "$DNS_MARK_FILE" ] || dns_uci_points_to_fakeip; then
			uci -q delete dhcp.@dnsmasq[0].filter_aaaa
		fi
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
	rm -f "$DNS_MARK_FILE"
	# Keep persistent + tmp backups for next FakeIP cycle (do not delete persist)
	rm -f "$DNS_BACKUP" "$DNS_BACKUP.noresolv" "$DNS_AAAA_BACKUP" "$DNS_LOCALUSE_BACKUP"
	log "dns restored"
}
