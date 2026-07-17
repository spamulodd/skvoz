#!/bin/sh
# Generate / run sing-box for hard-block VPN (FakeIP domains + CIDR).

. /usr/lib/rvpn/common.sh

SB_BIN=/usr/bin/sing-box

# JSON string array from domain list (escaped, validated).
sb_build_json_array() {
	awk '
		function esc(s,   t) {
			t = s
			gsub(/\\/, "\\\\", t)
			gsub(/"/, "\\\"", t)
			return t
		}
		/^[[:space:]]*#/ { next }
		/^[[:space:]]*$/ { next }
		{
			gsub(/[[:space:]]/, "")
			if ($0 ~ /^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$/) {
				n++
				d[n] = $0
			}
		}
		END {
			printf "["
			for (i = 1; i <= n; i++) {
				if (i > 1) printf ","
				printf "\"%s\"", esc(d[i])
			}
			printf "]"
		}
	' "$1"
}

# JSON string array from IPv4 CIDR list only.
sb_build_cidr_json_array() {
	awk '
		/^[[:space:]]*#/ { next }
		/^[[:space:]]*$/ { next }
		{
			gsub(/[[:space:]]/, "")
			if ($0 ~ /^[0-9]{1,3}(\.[0-9]{1,3}){3}\/[0-9]{1,2}$/) {
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
	valid_port "$tproxy" || tproxy=12345
	fake=$(uci_get fakeip_inet4_range)
	[ -n "$fake" ] || fake=198.18.0.0/15
	valid_ipv4_cidr "$fake" || fake=198.18.0.0/15
	ut_url=$(uci_get urltest_url)
	[ -n "$ut_url" ] || ut_url=https://www.gstatic.com/generate_204
	ut_iv=$(uci_get urltest_interval)
	[ -n "$ut_iv" ] || ut_iv=2m
	case "$ut_iv" in
	*[!A-Za-z0-9.]*) ut_iv=2m ;;
	esac
	ut_tol=$(uci_get urltest_tolerance)
	[ -n "$ut_tol" ] || ut_tol=100
	case "$ut_tol" in
	''|*[!0-9]*) ut_tol=100 ;;
	esac
	ll=$(uci_get log_level)
	case "$ll" in
	trace|debug|info|warn|error|fatal|panic) ;;
	*) ll=warn ;;
	esac

	clash_secret=$(ensure_clash_secret) || return 1
	clash_secret_j=$(json_escape "$clash_secret")
	ut_url_j=$(json_escape "$ut_url")
	listen_j=$(json_escape "$listen")
	fake_j=$(json_escape "$fake")
	ll_j=$(json_escape "$ll")
	ut_iv_j=$(json_escape "$ut_iv")

	vpn_dom=$(sb_build_json_array "$RVPN_RULES/vpn-domains.txt")
	games_dom=$(sb_build_json_array "$RVPN_RULES/games-domains.txt")
	vpn_cidr='[]'
	[ -f "$RVPN_RULES/vpn-cidr.txt" ] && vpn_cidr=$(sb_build_cidr_json_array "$RVPN_RULES/vpn-cidr.txt")

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
		valid_port "$port" || {
			log "ERROR: bad port for node $id"
			continue
		}
		tag_j=$(json_escape "$tag")
		server_j=$(json_escape "$server")
		case "$type" in
		hysteria2)
			pw=$(uci -q get "rvpn.$id.password")
			sni=$(uci -q get "rvpn.$id.sni")
			[ -n "$sni" ] || sni="$server"
			ins=$(uci -q get "rvpn.$id.insecure")
			[ "$ins" = "1" ] && insecure=true || insecure=false
			pw_j=$(json_escape "$pw")
			sni_j=$(json_escape "$sni")
			printf '{"type":"hysteria2","tag":"%s","server":"%s","server_port":%s,"password":"%s","tls":{"enabled":true,"server_name":"%s","insecure":%s}}\n' \
				"$tag_j" "$server_j" "$port" "$pw_j" "$sni_j" "$insecure" >>"$outbounds_tmp"
			echo "$tag" >>"$tags_tmp"
			;;
		vless)
			uuid=$(uci -q get "rvpn.$id.uuid")
			sni=$(uci -q get "rvpn.$id.sni")
			pbk=$(uci -q get "rvpn.$id.reality_public_key")
			sid=$(uci -q get "rvpn.$id.reality_short_id")
			uuid_j=$(json_escape "$uuid")
			sni_j=$(json_escape "$sni")
			pbk_j=$(json_escape "$pbk")
			sid_j=$(json_escape "$sid")
			printf '{"type":"vless","tag":"%s","server":"%s","server_port":%s,"uuid":"%s","packet_encoding":"xudp","tls":{"enabled":true,"server_name":"%s","utls":{"enabled":true,"fingerprint":"chrome"},"reality":{"enabled":true,"public_key":"%s","short_id":"%s"}},"flow":"xtls-rprx-vision"}\n' \
				"$tag_j" "$server_j" "$port" "$uuid_j" "$sni_j" "$pbk_j" "$sid_j" >>"$outbounds_tmp"
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
		tj=$(json_escape "$t")
		ut_out="$ut_out$sep\"$tj\""
		sep=,
	done <"$tags_tmp"
	ut_out="$ut_out]"

	obs="$obs,{\"type\":\"urltest\",\"tag\":\"rvpn-urltest\",\"outbounds\":$ut_out,\"url\":\"$ut_url_j\",\"interval\":\"$ut_iv_j\",\"tolerance\":$ut_tol}"
	obs="$obs,{\"type\":\"direct\",\"tag\":\"direct\"}"
	obs="$obs]"

	if [ "$vpn_cidr" != "[]" ] && [ -n "$vpn_cidr" ]; then
		inner=$(echo "$vpn_cidr" | sed 's/^\[//;s/\]$//')
		ip_route_json="[\"$fake_j\",$inner]"
	else
		ip_route_json="[\"$fake_j\"]"
	fi

	umask 077
	cat >"$RVPN_SB_JSON" <<EOF
{
  "log": {"level": "$ll_j", "timestamp": true},
  "experimental": {
    "clash_api": {
      "external_controller": "127.0.0.1:9090",
      "secret": "$clash_secret_j",
      "access_control_allow_origin": ["http://127.0.0.1", "http://192.168.1.1:81"],
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
      {"tag": "fakeip", "type": "fakeip", "inet4_range": "$fake_j"}
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
      "listen": "$listen_j",
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
      {"domain_suffix": $vpn_dom, "outbound": "rvpn-urltest"},
      {"ip_cidr": $ip_route_json, "outbound": "rvpn-urltest"}
    ],
    "final": "direct",
    "auto_detect_interface": true
  }
}
EOF
	chmod 600 "$RVPN_SB_JSON" 2>/dev/null || true

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
	sb_kill_ours
	sleep 1
	"$SB_BIN" run -c "$RVPN_SB_JSON" >/tmp/rvpn/sing-box.log 2>&1 &
	echo $! >"$RVPN_RUN/sing-box.pid"
	chmod 600 "$RVPN_RUN/sing-box.pid" 2>/dev/null || true
	sleep 2
	if [ -z "$(sb_pids)" ]; then
		log "ERROR: sing-box failed to start"
		tail -40 /tmp/rvpn/sing-box.log >>"$RVPN_LOG"
		return 1
	fi
	log "sing-box started"
	return 0
}

sb_stop() {
	sb_kill_ours
	rm -f "$RVPN_RUN/sing-box.pid"
	log "sing-box stopped"
}
