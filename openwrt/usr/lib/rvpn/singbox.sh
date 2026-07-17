#!/bin/sh
# Generate / run sing-box for hard-block VPN (FakeIP domains + CIDR).

. /usr/lib/rvpn/common.sh

SB_BIN=/usr/bin/sing-box

sb_build_json_array() {
	# $1 = file, strips comments
	awk '
		/^[[:space:]]*#/ { next }
		/^[[:space:]]*$/ { next }
		{
			gsub(/[[:space:]]/, "")
			if (length($0) > 0) {
				n++
				d[n] = $0
			}
		}
		END {
			printf "["
			for (i = 1; i <= n; i++) {
				if (i > 1) printf ","
				printf "\"%s\"", d[i]
			}
			printf "]"
		}
	' "$1"
}

sb_generate() {
	vpn=$(uci_get vpn_enabled)
	if [ "$vpn" != "1" ]; then
		rm -f "$RVPN_SB_JSON"
		return 0
	fi

	listen=$(uci_get dns_listen)
	[ -n "$listen" ] || listen=127.0.0.42
	tproxy=$(uci_get tproxy_port)
	[ -n "$tproxy" ] || tproxy=12345
	fake=$(uci_get fakeip_inet4_range)
	[ -n "$fake" ] || fake=198.18.0.0/15
	api=$(uci_get clash_api)
	[ -n "$api" ] || api=0.0.0.0:9090
	api_host=${api%:*}
	api_port=${api##*:}
	ut_url=$(uci_get urltest_url)
	[ -n "$ut_url" ] || ut_url=https://www.gstatic.com/generate_204
	ut_iv=$(uci_get urltest_interval)
	[ -n "$ut_iv" ] || ut_iv=2m
	ut_tol=$(uci_get urltest_tolerance)
	[ -n "$ut_tol" ] || ut_tol=100
	ll=$(uci_get log_level)
	[ -n "$ll" ] || ll=warn

	vpn_dom=$(sb_build_json_array "$RVPN_RULES/vpn-domains.txt")
	games_dom=$(sb_build_json_array "$RVPN_RULES/games-domains.txt")
	vpn_cidr='[]'
	[ -f "$RVPN_RULES/vpn-cidr.txt" ] && vpn_cidr=$(sb_build_json_array "$RVPN_RULES/vpn-cidr.txt")

	outbounds_tmp="$RVPN_RUN/outbounds.jsonl"
	tags_tmp="$RVPN_RUN/tags.txt"
	: >"$outbounds_tmp"
	: >"$tags_tmp"

	for id in $(uci -q show rvpn | sed -n 's/^rvpn\.\([^=]*\)=node$/\1/p'); do
		en=$(uci -q get "rvpn.$id.enabled")
		[ "$en" = "1" ] || continue
		type=$(uci -q get "rvpn.$id.type")
		tag=$(uci -q get "rvpn.$id.tag")
		[ -n "$tag" ] || tag="$id"
		server=$(uci -q get "rvpn.$id.server")
		port=$(uci -q get "rvpn.$id.port")
		case "$type" in
		hysteria2)
			pw=$(uci -q get "rvpn.$id.password")
			sni=$(uci -q get "rvpn.$id.sni")
			[ -n "$sni" ] || sni="$server"
			ins=$(uci -q get "rvpn.$id.insecure")
			[ "$ins" = "1" ] && insecure=true || insecure=false
			printf '{"type":"hysteria2","tag":"%s","server":"%s","server_port":%s,"password":"%s","tls":{"enabled":true,"server_name":"%s","insecure":%s}}\n' \
				"$tag" "$server" "$port" "$pw" "$sni" "$insecure" >>"$outbounds_tmp"
			echo "$tag" >>"$tags_tmp"
			;;
		vless)
			uuid=$(uci -q get "rvpn.$id.uuid")
			sni=$(uci -q get "rvpn.$id.sni")
			pbk=$(uci -q get "rvpn.$id.reality_public_key")
			sid=$(uci -q get "rvpn.$id.reality_short_id")
			printf '{"type":"vless","tag":"%s","server":"%s","server_port":%s,"uuid":"%s","packet_encoding":"xudp","tls":{"enabled":true,"server_name":"%s","utls":{"enabled":true,"fingerprint":"chrome"},"reality":{"enabled":true,"public_key":"%s","short_id":"%s"}},"flow":"xtls-rprx-vision"}\n' \
				"$tag" "$server" "$port" "$uuid" "$sni" "$pbk" "$sid" >>"$outbounds_tmp"
			echo "$tag" >>"$tags_tmp"
			;;
		esac
	done

	if [ ! -s "$tags_tmp" ]; then
		log "ERROR: no enabled VPN nodes"
		return 1
	fi

	obs='['
	sep=
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		obs="$obs$sep$line"
		sep=,
	done <"$outbounds_tmp"

	ut_out='['
	sep=
	while IFS= read -r t; do
		[ -n "$t" ] || continue
		ut_out="$ut_out$sep\"$t\""
		sep=,
	done <"$tags_tmp"
	ut_out="$ut_out]"

	obs="$obs,{\"type\":\"urltest\",\"tag\":\"rvpn-urltest\",\"outbounds\":$ut_out,\"url\":\"$ut_url\",\"interval\":\"$ut_iv\",\"tolerance\":$ut_tol}"
	obs="$obs,{\"type\":\"direct\",\"tag\":\"direct\"}"
	obs="$obs]"

	# ip_cidr route: fakeip + telegram/meta ranges
	ip_route="$fake"
	if [ "$vpn_cidr" != "[]" ] && [ -n "$vpn_cidr" ]; then
		# merge: ["198.18..."] + cidrs without outer brackets
		inner=$(echo "$vpn_cidr" | sed 's/^\[//;s/\]$//')
		ip_route_json="[\"$fake\",$inner]"
	else
		ip_route_json="[\"$fake\"]"
	fi

	cat >"$RVPN_SB_JSON" <<EOF
{
  "log": {"level": "$ll", "timestamp": true},
  "experimental": {
    "clash_api": {
      "external_controller": "$api_host:$api_port",
      "access_control_allow_origin": ["*"],
      "access_control_allow_private_network": true
    },
    "cache_file": {
      "enabled": true,
      "path": "/tmp/rvpn/cache.db",
      "store_fakeip": true
    }
  },
  "dns": {
    "servers": [
      {"tag": "local", "type": "udp", "server": "8.8.8.8"},
      {"tag": "yandex", "type": "udp", "server": "77.88.8.8"},
      {"tag": "fakeip", "type": "fakeip", "inet4_range": "$fake"}
    ],
    "rules": [
      {"query_type": ["HTTPS", "SVCB"], "action": "reject"},
      {"domain_suffix": $vpn_dom, "server": "fakeip", "rewrite_ttl": 1}
    ],
    "final": "local",
    "independent_cache": true,
    "strategy": "ipv4_only"
  },
  "inbounds": [
    {
      "type": "tproxy",
      "tag": "tproxy-in",
      "listen": "0.0.0.0",
      "listen_port": $tproxy
    },
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 10808
    },
    {
      "type": "direct",
      "tag": "dns-in",
      "listen": "$listen",
      "listen_port": 53
    }
  ],
  "outbounds": $obs,
  "route": {
    "default_domain_resolver": "local",
    "rules": [
      {"action": "sniff", "sniffer": ["http", "tls", "quic", "dns"], "timeout": "500ms"},
      {"protocol": "dns", "action": "hijack-dns"},
      {"ip_is_private": true, "outbound": "direct"},
      {"domain_suffix": $games_dom, "outbound": "direct"},
      {"network": "udp", "port": 443, "domain_suffix": $vpn_dom, "action": "reject"},
      {"network": "udp", "port": 443, "ip_cidr": $ip_route_json, "action": "reject"},
      {"domain_suffix": $vpn_dom, "outbound": "rvpn-urltest"},
      {"ip_cidr": $ip_route_json, "outbound": "rvpn-urltest"}
    ],
    "final": "direct",
    "auto_detect_interface": true
  }
}
EOF

	if ! "$SB_BIN" check -c "$RVPN_SB_JSON" >/tmp/rvpn/sb-check.log 2>&1; then
		log "ERROR: sing-box check failed"
		cat /tmp/rvpn/sb-check.log >>"$RVPN_LOG"
		return 1
	fi
	log "sing-box config OK"
	return 0
}

sb_start() {
	vpn=$(uci_get vpn_enabled)
	[ "$vpn" = "1" ] || return 0
	sb_generate || return 1
	killall -9 sing-box 2>/dev/null || true
	sleep 1
	"$SB_BIN" run -c "$RVPN_SB_JSON" >/tmp/rvpn/sing-box.log 2>&1 &
	echo $! >"$RVPN_RUN/sing-box.pid"
	sleep 2
	if ! pgrep -f 'sing-box.json' >/dev/null 2>&1; then
		log "ERROR: sing-box failed to start"
		tail -40 /tmp/rvpn/sing-box.log >>"$RVPN_LOG"
		return 1
	fi
	log "sing-box started"
	return 0
}

sb_stop() {
	killall -9 sing-box 2>/dev/null || true
	rm -f "$RVPN_RUN/sing-box.pid"
	log "sing-box stopped"
}
