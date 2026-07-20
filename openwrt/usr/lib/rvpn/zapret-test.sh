#!/bin/sh
# Probe DPI-bypass targets per Flowseal strategy; pick best (most OK, then fastest).
[ "${RVPN_ZAPRET_TEST_SOURCED:-0}" = "1" ] && return 0
RVPN_ZAPRET_TEST_SOURCED=1

. /usr/lib/rvpn/common.sh
. /usr/lib/rvpn/zapret.sh
. /usr/lib/rvpn/zapret-strat.sh
. /usr/lib/rvpn/nft.sh

ZAP_TEST_LOG=$RVPN_RUN/zapret_test.log
ZAP_TEST_JSON=$RVPN_RUN/zapret_test.json
ZAP_TEST_TSV=$RVPN_RUN/zapret_test.tsv

# Targets: real HTTPS endpoints that DPI often breaks (router resolves via 1.1.1.1).
# YouTube/Discord stay useful even when FakeIP VPN is on — we bypass local DNS.
zapret_test_targets() {
	cat <<'EOF'
www.youtube.com|/generate_204
discord.com|/
rr3---sn-something.googlevideo.com|/
www.google.com|/generate_204
rutracker.org|/
EOF
}

# Skip googlevideo host that may NXDOMAIN — use stable set:
zapret_test_targets_stable() {
	cat <<'EOF'
www.youtube.com|/generate_204
discord.com|/
www.google.com|/generate_204
rutracker.org|/
archiveofourown.org|/
EOF
}

zapret_resolve_a() {
	host=$1
	# Prefer dig, then nslookup, then getent
	ip=
	if command -v dig >/dev/null 2>&1; then
		ip=$(dig +short +time=2 +tries=1 "$host" @1.1.1.1 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
	fi
	if [ -z "$ip" ] && command -v nslookup >/dev/null 2>&1; then
		ip=$(nslookup "$host" 1.1.1.1 2>/dev/null | awk '/^Address: /{a=$2} END{print a}' | grep -E '^[0-9]+\.')
	fi
	if [ -z "$ip" ]; then
		ip=$(curl -sS --connect-timeout 2 --max-time 4 "https://1.1.1.1/dns-query?name=${host}&type=A" \
			-H 'accept: application/dns-json' 2>/dev/null | \
			sed -n 's/.*"data":"\([0-9.]*\)".*/\1/p' | head -1)
	fi
	echo "$ip"
}

# Returns 0 if HTTP status looks OK. Prints "ms status"
zapret_probe_one() {
	host=$1
	path=$2
	[ -n "$path" ] || path=/
	ip=$(zapret_resolve_a "$host")
	[ -n "$ip" ] || {
		echo "0 fail"
		return 1
	}
	# --resolve forces real IP; traffic leaves WAN → nfqws hostlist can match SNI/host
	code=$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' \
		--connect-timeout 4 --max-time 10 \
		--resolve "${host}:443:${ip}" \
		--resolve "${host}:80:${ip}" \
		"https://${host}${path}" 2>/dev/null) || code="000 9.99"
	http=${code%% *}
	sec=${code##* }
	# busybox awk may lack float — use ms via sed
	ms=$(echo "$sec" | awk '{printf "%d", $1*1000}')
	case "$http" in
	200|204|301|302|303|307|308|401|403)
		# 403 sometimes still means TLS+HTTP got through DPI
		echo "$ms ok"
		return 0
		;;
	*)
		echo "${ms:-0} fail"
		return 1
		;;
	esac
}

zapret_test_strategy() {
	id=$1
	[ -n "$id" ] || return 1
	# Apply strategy without flipping UCI permanently until autotune commits
	old=$(uci_get zapret_strategy)
	uci set rvpn.main.zapret_strategy="$id"
	# ensure zapret layer on for test
	was=$(uci_get zapret_enabled)
	uci set rvpn.main.zapret_enabled='1'
	zapret_start || {
		[ -n "$old" ] && uci set rvpn.main.zapret_strategy="$old"
		[ "$was" = "1" ] || uci set rvpn.main.zapret_enabled="$was"
		echo "0 0 0"
		return 1
	}
	nft_apply_zapret >/dev/null 2>&1 || true
	sleep 1

	ok=0
	n=0
	total_ms=0
	while IFS='|' read -r host path; do
		[ -n "$host" ] || continue
		n=$((n + 1))
		res=$(zapret_probe_one "$host" "$path")
		ms=${res%% *}
		st=${res##* }
		printf '%s\t%s\t%s\t%s\n' "$id" "$host" "$st" "$ms" >>"$ZAP_TEST_TSV"
		if [ "$st" = "ok" ]; then
			ok=$((ok + 1))
			total_ms=$((total_ms + ms))
		fi
	done <<EOF
$(zapret_test_targets_stable)
EOF

	# restore zapret_enabled flag in UCI only if we changed for test caller — autotune handles
	echo "$ok $n $total_ms"
}

zapret_test_autotune() {
	mkdir -p "$RVPN_RUN"
	: >"$ZAP_TEST_TSV"
	: >"$ZAP_TEST_LOG"
	log "zapret autotune: start"
	echo "$(date -u +%Y-%m-%dT%H:%MZ) autotune start" >>"$ZAP_TEST_LOG"

	prev_strat=$(uci_get zapret_strategy)
	prev_zap=$(uci_get zapret_enabled)
	uci set rvpn.main.zapret_enabled='1'
	uci commit rvpn

	best_id=
	best_ok=-1
	best_ms=9999999

	for id in $(zapret_strat_list); do
		[ -f "$ZAP_STRAT_DIR/${id}.strategy" ] || continue
		echo "testing $id" >>"$ZAP_TEST_LOG"
		res=$(zapret_test_strategy "$id")
		ok=$(echo "$res" | awk '{print $1}')
		n=$(echo "$res" | awk '{print $2}')
		ms=$(echo "$res" | awk '{print $3}')
		case "$ok" in ''|*[!0-9]*) ok=0 ;; esac
		case "$ms" in ''|*[!0-9]*) ms=999999 ;; esac
		echo "$id ok=$ok/$n ms=$ms" >>"$ZAP_TEST_LOG"
		log "zapret test $id: $ok/$n ms=$ms"
		if [ "$ok" -gt "$best_ok" ] || { [ "$ok" -eq "$best_ok" ] && [ "$ms" -lt "$best_ms" ]; }; then
			best_ok=$ok
			best_ms=$ms
			best_id=$id
		fi
	done

	if [ -z "$best_id" ] || [ "$best_ok" -le 0 ]; then
		# keep previous or default
		[ -n "$prev_strat" ] && best_id=$prev_strat
		[ -n "$best_id" ] || best_id=$(zapret_strat_default)
		log "zapret autotune: no winner — keep $best_id"
	else
		log "zapret autotune: best=$best_id ok=$best_ok ms=$best_ms"
	fi

	uci set rvpn.main.zapret_strategy="$best_id"
	uci set rvpn.main.zapret_enabled="$prev_zap"
	# if was on, stay on; if off, leave off but strategy saved
	uci commit rvpn

	# Apply if zapret still enabled
	if [ "$(uci_get zapret_enabled)" = "1" ]; then
		zapret_start
		nft_apply_zapret || true
	fi

	bj=$(json_escape "$best_id")
	printf '{"ok":1,"best":"%s","score":%s,"latency_ms":%s,"ts":"%s"}\n' \
		"$bj" "${best_ok:-0}" "${best_ms:-0}" "$(date -u +%Y-%m-%dT%H:%MZ 2>/dev/null || date)" \
		>"$ZAP_TEST_JSON"
	cat "$ZAP_TEST_JSON"
	return 0
}

zapret_test_one() {
	id=$1
	[ -n "$id" ] || id=$(zapret_strat_id)
	mkdir -p "$RVPN_RUN"
	: >"$ZAP_TEST_TSV"
	res=$(zapret_test_strategy "$id")
	ok=$(echo "$res" | awk '{print $1}')
	n=$(echo "$res" | awk '{print $2}')
	ms=$(echo "$res" | awk '{print $3}')
	uci set rvpn.main.zapret_strategy="$id"
	uci commit rvpn
	printf '{"ok":1,"strategy":"%s","passed":%s,"total":%s,"latency_ms":%s}\n' \
		"$(json_escape "$id")" "${ok:-0}" "${n:-0}" "${ms:-0}" | tee "$ZAP_TEST_JSON"
}
