#!/bin/sh
# nft: TPROXY FakeIP+CIDR; zapret NFQUEUE; optional QUIC drop (YT thumbs).

. /usr/lib/rvpn/common.sh

nft_flush_vpn() {
	nft list table inet rvpn_vpn >/dev/null 2>&1 && nft delete table inet rvpn_vpn || true
	ip rule del fwmark 0x1 lookup 100 2>/dev/null || true
	ip route flush table 100 2>/dev/null || true
}

nft_flush_zapret() {
	nft list table inet rvpn_zapret >/dev/null 2>&1 && nft delete table inet rvpn_zapret || true
	rvpn_ui_cache_flush
}

nft_flush_quic() {
	nft list table inet rvpn_quic >/dev/null 2>&1 && nft delete table inet rvpn_quic || true
}

nft_flush_doh() {
	nft list table inet rvpn_doh >/dev/null 2>&1 && nft delete table inet rvpn_doh || true
	nft list table inet rvpn_dns >/dev/null 2>&1 && nft delete table inet rvpn_dns || true
}

nft_flush_all() {
	nft_flush_zapret
	nft_flush_vpn
	nft_flush_quic
	nft_flush_doh
	log "nft flushed"
}

nft_build_doh_elements() {
	f="$RVPN_RULES/doh-cidr.txt"
	[ -f "$f" ] || return 0
	awk '
		/^[[:space:]]*#/ { next }
		/^[[:space:]]*$/ { next }
		{
			gsub(/[[:space:]]/, "")
			if ($0 ~ /^[0-9]{1,3}(\.[0-9]{1,3}){3}\/[0-9]{1,2}$/) {
				if (n++) printf ", "
				printf "%s", $0
			}
		}
	' "$f"
}

nft_apply_doh() {
	# Force browsers back to router DNS (block DoH/DoT)
	zap=$(uci_get zapret_enabled)
	vpn=$(uci_get vpn_enabled)
	nft_flush_doh
	if [ "$zap" != "1" ] && [ "$vpn" != "1" ]; then
		return 0
	fi
	elems=$(nft_build_doh_elements)
	set_block=""
	cidr_rules=""
	if [ -n "$elems" ]; then
		set_block="
	set doh_cidr {
		type ipv4_addr
		flags interval
		auto-merge
		elements = { $elems }
	}"
		cidr_rules="
		iifname \"br-lan\" ip daddr @doh_cidr tcp dport 443 reject
		iifname \"br-lan\" ip daddr @doh_cidr udp dport 443 reject"
	fi
	if nft -f - <<EOF
table inet rvpn_doh {
$set_block
	chain prerouting {
		type filter hook prerouting priority -160; policy accept;
		iifname "br-lan" meta l4proto tcp tcp dport 853 reject
		iifname "br-lan" meta l4proto udp udp dport 853 reject
$cidr_rules
	}
}
EOF
	then
		log "nft DoH/DoT block on br-lan"
	else
		log "WARN: nft doh apply failed"
	fi

	# NAT redirect: force LAN DNS to router (filter-hook redirect unsupported on mt7621)
	nft list table inet rvpn_dns >/dev/null 2>&1 && nft delete table inet rvpn_dns || true
	if nft -f - <<EOF
table inet rvpn_dns {
	chain prerouting {
		type nat hook prerouting priority dstnat; policy accept;
		iifname "br-lan" meta l4proto udp udp dport 53 redirect to :53
		iifname "br-lan" meta l4proto tcp tcp dport 53 redirect to :53
	}
}
EOF
	then
		log "nft DNS redirect (nat) on br-lan"
	else
		log "WARN: nft DNS redirect unsupported"
	fi
}

nft_build_cidr_elements() {
	f="$RVPN_RULES/vpn-cidr.txt"
	[ -f "$f" ] || return 0
	# Only IPv4 CIDR — reject junk before splicing into nft -f
	awk '
		/^[[:space:]]*#/ { next }
		/^[[:space:]]*$/ { next }
		{
			gsub(/[[:space:]]/, "")
			if ($0 ~ /^[0-9]{1,3}(\.[0-9]{1,3}){3}\/[0-9]{1,2}$/) {
				if (n++) printf ", "
				printf "%s", $0
			}
		}
	' "$f"
}

# Fingerprint of CIDR set (+ port/fake) to skip full table recreate.
nft_vpn_fp() {
	port=$1
	fake=$2
	elems=$3
	printf '%s|%s|%s' "$port" "$fake" "$elems" | md5sum 2>/dev/null | awk '{print $1}'
}

nft_apply_quic() {
	# Reject QUIC on WAN path only. NEVER reject FakeIP / vpn_cidr — that
	# runs before tproxy and broke YouTube API + Telegram media UDP.
	# TG: DC/CDN real IPs live in vpn_cidr → UDP/443 accepted → VPN tproxy.
	# MTProto on other UDP ports is untouched (only udp dport 443 rejected).
	dq=$(uci_get disable_quic)
	zap=$(uci_get zapret_enabled)
	vpn=$(uci_get vpn_enabled)
	nft_flush_quic
	if [ "$dq" != "1" ]; then
		return 0
	fi
	if [ "$zap" != "1" ] && [ "$vpn" != "1" ]; then
		return 0
	fi
	fake=$(uci_get fakeip_inet4_range)
	[ -n "$fake" ] || fake=198.18.0.0/15
	elems=$(nft_build_cidr_elements)
	set_block=""
	skip_cidr=""
	if [ -n "$elems" ]; then
		set_block="
	set vpn_cidr {
		type ipv4_addr
		flags interval
		auto-merge
		elements = { $elems }
	}"
		skip_cidr="
		iifname \"br-lan\" ip daddr @vpn_cidr accept"
	fi
	if nft -f - <<EOF
table inet rvpn_quic {
$set_block
	chain prerouting {
		type filter hook prerouting priority -155; policy accept;
		iifname "br-lan" ip daddr $fake accept
$skip_cidr
		iifname "br-lan" meta l4proto udp udp dport 443 reject
	}
}
EOF
	then
		log "nft QUIC reject (skip FakeIP/vpn_cidr)"
	else
		log "WARN: nft quic apply failed"
	fi
}

nft_apply_vpn() {
	vpn=$(uci_get vpn_enabled)
	[ "$vpn" = "1" ] || { nft_flush_vpn; rm -f "$RVPN_RUN/nft_vpn.fp"; return 0; }

	port=$(uci_get tproxy_port)
	[ -n "$port" ] || port=12345
	fake=$(uci_get fakeip_inet4_range)
	[ -n "$fake" ] || fake=198.18.0.0/15

	elems=$(nft_build_cidr_elements)
	fp=$(nft_vpn_fp "$port" "$fake" "$elems")
	# Fast path: table exists and fingerprint unchanged — try set replace only
	if [ -n "$fp" ] && [ -f "$RVPN_RUN/nft_vpn.fp" ] && \
		[ "$(cat "$RVPN_RUN/nft_vpn.fp" 2>/dev/null)" = "$fp" ] && \
		nft list table inet rvpn_vpn >/dev/null 2>&1; then
		if [ -n "$elems" ] && nft list set inet rvpn_vpn vpn_cidr >/dev/null 2>&1; then
			# Already in sync
			return 0
		fi
		if [ -z "$elems" ]; then
			return 0
		fi
	fi

	# Hot update: flush/add elements without deleting table (less traffic blip)
	if [ -n "$fp" ] && [ -n "$elems" ] && nft list table inet rvpn_vpn >/dev/null 2>&1 && \
		nft list set inet rvpn_vpn vpn_cidr >/dev/null 2>&1; then
		if nft flush set inet rvpn_vpn vpn_cidr 2>/dev/null && \
			nft add element inet rvpn_vpn vpn_cidr "{ $elems }" 2>/dev/null; then
			echo "$fp" >"$RVPN_RUN/nft_vpn.fp"
			log "nft vpn_cidr set updated (hot)"
			return 0
		fi
		log "WARN: nft vpn hot update failed — full recreate"
	fi

	set_block=""
	cidr_pre=""
	cidr_out=""
	if [ -n "$elems" ]; then
		set_block="
	set vpn_cidr {
		type ipv4_addr
		flags interval
		auto-merge
		elements = { $elems }
	}"
		cidr_pre="
		iifname \"br-lan\" ip daddr @vpn_cidr meta l4proto tcp tproxy ip to :$port meta mark set 0x1 counter
		iifname \"br-lan\" ip daddr @vpn_cidr meta l4proto udp tproxy ip to :$port meta mark set 0x1 counter"
		cidr_out="
		ip daddr @vpn_cidr meta l4proto tcp meta mark set 0x1 counter
		ip daddr @vpn_cidr meta l4proto udp meta mark set 0x1 counter"
	fi

	nft_flush_vpn

	ip rule del fwmark 0x1 lookup 100 2>/dev/null || true
	ip rule add fwmark 0x1 lookup 100 priority 100 2>/dev/null || true
	ip route replace local default dev lo table 100 2>/dev/null || true

	if nft -f - <<EOF
table inet rvpn_vpn {
$set_block
	chain prerouting {
		type filter hook prerouting priority mangle; policy accept;
		iifname "br-lan" ip daddr $fake meta l4proto tcp tproxy ip to :$port meta mark set 0x1 counter
		iifname "br-lan" ip daddr $fake meta l4proto udp tproxy ip to :$port meta mark set 0x1 counter
$cidr_pre
	}
	chain output {
		type route hook output priority mangle; policy accept;
		ip daddr $fake meta l4proto tcp meta mark set 0x1 counter
		ip daddr $fake meta l4proto udp meta mark set 0x1 counter
$cidr_out
	}
}
EOF
	then
		[ -n "$fp" ] && echo "$fp" >"$RVPN_RUN/nft_vpn.fp"
		log "nft vpn tproxy :$port fake=$fake cidr=$([ -n "$elems" ] && echo yes || echo no)"
	else
		log "ERROR: nft vpn apply failed"
		rm -f "$RVPN_RUN/nft_vpn.fp"
		nft_flush_vpn
		return 1
	fi
}

nft_apply_zapret() {
	zap=$(uci_get zapret_enabled)
	[ "$zap" = "1" ] || { nft_flush_zapret; return 0; }

	qnum=$(uci_get zapret_qnum)
	[ -n "$qnum" ] || qnum=200
	fake=$(uci_get fakeip_inet4_range)
	[ -n "$fake" ] || fake=198.18.0.0/15
	elems=$(nft_build_cidr_elements)
	set_block=""
	skip_cidr=""
	if [ -n "$elems" ]; then
		set_block="
	set vpn_cidr {
		type ipv4_addr
		flags interval
		auto-merge
		elements = { $elems }
	}"
		skip_cidr="
		ip daddr @vpn_cidr return"
	fi

	nft_flush_zapret

	# Early TCP → nfqws. Never touch FakeIP / Telegram·Meta CIDR / marked tproxy.
	if nft -f - <<EOF
table inet rvpn_zapret {
$set_block
	chain postrouting {
		type filter hook postrouting priority mangle; policy accept;
		oifname "lo" return
		meta mark 0x1 return
		ip daddr $fake return
$skip_cidr
		meta l4proto tcp tcp dport { 80, 443 } ct original packets 1-12 queue flags bypass to $qnum
	}
}
EOF
	then
		log "nft zapret queue $qnum (skip FakeIP/vpn_cidr)"
	else
		log "ERROR: nft zapret apply failed"
		return 1
	fi
}
