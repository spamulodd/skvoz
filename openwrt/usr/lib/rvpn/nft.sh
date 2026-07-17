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
}

nft_flush_quic() {
	nft list table inet rvpn_quic >/dev/null 2>&1 && nft delete table inet rvpn_quic || true
}

nft_flush_all() {
	nft_flush_zapret
	nft_flush_vpn
	nft_flush_quic
	log "nft flushed"
}

nft_build_cidr_elements() {
	f="$RVPN_RULES/vpn-cidr.txt"
	[ -f "$f" ] || return 0
	awk '
		/^[[:space:]]*#/ { next }
		/^[[:space:]]*$/ { next }
		{
			gsub(/[[:space:]]/, "")
			if (length($0) > 0) {
				if (n++) printf ", "
				printf "%s", $0
			}
		}
	' "$f"
}

nft_apply_quic() {
	# Force TCP so nfqws can desync YT image CDNs (HTTP/3 often stuck under DPI)
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
	if nft -f - <<'EOF'
table inet rvpn_quic {
	chain prerouting {
		type filter hook prerouting priority -155; policy accept;
		iifname "br-lan" meta l4proto udp udp dport 443 reject
	}
}
EOF
	then
		log "nft QUIC reject on br-lan udp/443"
	else
		log "WARN: nft quic apply failed"
	fi
}

nft_apply_vpn() {
	vpn=$(uci_get vpn_enabled)
	[ "$vpn" = "1" ] || { nft_flush_vpn; return 0; }

	port=$(uci_get tproxy_port)
	[ -n "$port" ] || port=12345
	fake=$(uci_get fakeip_inet4_range)
	[ -n "$fake" ] || fake=198.18.0.0/15

	elems=$(nft_build_cidr_elements)
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
		# output: mark only (tproxy in output unsupported on many mt7621 builds)
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
		log "nft vpn tproxy :$port fake=$fake cidr=$([ -n "$elems" ] && echo yes || echo no)"
	else
		log "ERROR: nft vpn apply failed"
		nft_flush_vpn
		return 1
	fi
}

nft_apply_zapret() {
	zap=$(uci_get zapret_enabled)
	[ "$zap" = "1" ] || { nft_flush_zapret; return 0; }

	qnum=$(uci_get zapret_qnum)
	[ -n "$qnum" ] || qnum=200

	nft_flush_zapret

	# Only LAN→WAN early TCP — skip already-tproxy'd / lo
	if nft -f - <<EOF
table inet rvpn_zapret {
	chain postrouting {
		type filter hook postrouting priority mangle; policy accept;
		oifname != "lo" meta l4proto tcp tcp dport { 80, 443 } ct original packets 1-12 queue flags bypass to $qnum
	}
}
EOF
	then
		log "nft zapret queue $qnum (br-lan only)"
	else
		log "ERROR: nft zapret apply failed"
		return 1
	fi
}
