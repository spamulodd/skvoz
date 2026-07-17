#!/bin/sh
# nft: TPROXY FakeIP + VPN CIDRs → sing-box; zapret NFQUEUE for TCP 80/443.

. /usr/lib/rvpn/common.sh

TABLE_VPN="inet rvpn_vpn"
TABLE_ZAP="inet rvpn_zapret"

nft_flush_vpn() {
	nft list table inet rvpn_vpn >/dev/null 2>&1 && nft delete table inet rvpn_vpn || true
	ip rule del fwmark 0x1 lookup 100 2>/dev/null || true
	ip route flush table 100 2>/dev/null || true
}

nft_flush_zapret() {
	nft list table inet rvpn_zapret >/dev/null 2>&1 && nft delete table inet rvpn_zapret || true
}

nft_flush_all() {
	nft_flush_vpn
	nft_flush_zapret
	log "nft flushed"
}

nft_build_cidr_elements() {
	# stdout: 1.2.3.0/24, 5.6.0.0/16
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

nft_apply_vpn() {
	vpn=$(uci_get vpn_enabled)
	[ "$vpn" = "1" ] || { nft_flush_vpn; return 0; }

	port=$(uci_get tproxy_port)
	[ -n "$port" ] || port=12345
	fake=$(uci_get fakeip_inet4_range)
	[ -n "$fake" ] || fake=198.18.0.0/15

	elems=$(nft_build_cidr_elements)
	set_block=""
	cidr_rules=""
	if [ -n "$elems" ]; then
		set_block="
	set vpn_cidr {
		type ipv4_addr
		flags interval
		auto-merge
		elements = { $elems }
	}"
		cidr_rules="
		iifname \"br-lan\" ip daddr @vpn_cidr meta l4proto tcp tproxy ip to :$port meta mark set 0x1 counter
		iifname \"br-lan\" ip daddr @vpn_cidr meta l4proto udp tproxy ip to :$port meta mark set 0x1 counter"
		cidr_out="
		ip daddr @vpn_cidr meta l4proto tcp meta mark set 0x1 counter
		ip daddr @vpn_cidr meta l4proto udp meta mark set 0x1 counter"
	fi

	nft_flush_vpn

	ip rule add fwmark 0x1 lookup 100 priority 100 2>/dev/null || true
	ip route replace local default dev lo table 100 2>/dev/null || true

	if nft -f - <<EOF
table inet rvpn_vpn {
$set_block
	chain prerouting {
		type filter hook prerouting priority mangle; policy accept;
		iifname "br-lan" ip daddr $fake meta l4proto tcp tproxy ip to :$port meta mark set 0x1 counter
		iifname "br-lan" ip daddr $fake meta l4proto udp tproxy ip to :$port meta mark set 0x1 counter
$cidr_rules
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

	if nft -f - <<EOF
table inet rvpn_zapret {
	chain postrouting {
		type filter hook postrouting priority mangle; policy accept;
		oifname != "lo" meta l4proto tcp tcp dport { 80, 443 } ct original packets 1-12 queue flags bypass to $qnum
	}
	chain output {
		type filter hook output priority mangle; policy accept;
		oifname != "lo" meta l4proto tcp tcp dport { 80, 443 } ct original packets 1-12 queue flags bypass to $qnum
	}
}
EOF
	then
		log "nft zapret queue $qnum"
	else
		log "ERROR: nft zapret apply failed"
		return 1
	fi
}
