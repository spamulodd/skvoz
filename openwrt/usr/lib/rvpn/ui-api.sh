#!/bin/sh
# JSON helpers for Skvoz web UI (sourced by CGI).
. /usr/lib/rvpn/common.sh

RVPN_ADBLOCK_ALLOW=$RVPN_RULES/adblock-allow.txt
RVPN_ADBLOCK_USER=$RVPN_RULES/adblock-user.txt
RVPN_LAST_FAILOPEN=$RVPN_RUN/last_failopen
RVPN_WD_PID=${RVPN_WD_PID:-$RVPN_RUN/watchdog.pid}

# Count non-comment domains/CIDRs in a rules file.
ui_count_lines() {
	[ -f "$1" ] || { echo 0; return 0; }
	list_domains "$1" 2>/dev/null | wc -l | tr -d ' '
}

# Append domain to a user rules file (idempotent). Header comment optional.
ui_list_add() {
	file=$1
	header=$2
	raw=$3
	d=$(normalize_domain "$raw")
	valid_domain_token "$d" || return 1
	mkdir -p "$RVPN_RULES"
	if [ ! -f "$file" ]; then
		[ -n "$header" ] && printf '%s\n' "$header" >"$file"
		touch "$file"
	fi
	if domain_in_file "$file" "$d"; then
		echo "$d"
		return 0
	fi
	printf '%s\n' "$d" >>"$file"
	echo "$d"
}

ui_list_del() {
	file=$1
	raw=$2
	header=$3
	d=$(normalize_domain "$raw")
	valid_domain_token "$d" || return 1
	[ -f "$file" ] || return 0
	tmp=$RVPN_RUN/ui-list.$$
	list_domains "$file" | grep -vxF "$d" >"$tmp" || true
	{
		[ -n "$header" ] && printf '%s\n' "$header"
		cat "$tmp"
	} >"$file"
	rm -f "$tmp"
	echo "$d"
}

# True if host is sunk by dnsmasq adblock conf (exact or parent suffix).
ui_adblock_sinks_host() {
	host=$1
	conf=/tmp/dnsmasq.d/rvpn-adblock.conf
	[ -f "$conf" ] || return 1
	awk -v h="$host" '
		BEGIN { h = tolower(h) }
		/^address=\// {
			s = $0
			sub(/^address=\//, "", s)
			sub(/\/.*/, "", s)
			s = tolower(s)
			if (s == "") next
			if (h == s) { found = 1; exit }
			alen = length(s)
			hlen = length(h)
			if (hlen > alen && substr(h, hlen - alen, alen + 1) == ("." s)) { found = 1; exit }
		}
		END { exit found ? 0 : 1 }
	' "$conf"
}

# Suffix/exact match against list file. 0 = match.
ui_domain_in_list_suffix() {
	host=$1
	file=$2
	[ -f "$file" ] || return 1
	awk -v h="$host" '
		function clean(s) {
			sub(/#.*/, "", s)
			gsub(/[[:space:]]/, "", s)
			return tolower(s)
		}
		{
			a = clean($0)
			if (a == "") next
			if (h == a) { found=1; exit }
			alen = length(a)
			hlen = length(h)
			if (hlen > alen && substr(h, hlen - alen, alen + 1) == ("." a)) { found=1; exit }
		}
		END { exit found ? 0 : 1 }
	' "$file"
}

# Resolve layer for a hostname (adblock → games → vpn → dpi → direct).
ui_route_lookup() {
	raw=$1
	d=$(normalize_domain "$raw")
	valid_domain_token "$d" || {
		echo '{"ok":0,"error":"bad_domain"}'
		return 1
	}
	dj=$(json_escape "$d")
	layer=direct
	detail="default WAN"
	src=

	if [ "$(uci_get adblock_enabled)" = "1" ]; then
		# allow wins
		if ui_domain_in_list_suffix "$d" "$RVPN_ADBLOCK_ALLOW"; then
			:
		elif ui_adblock_sinks_host "$d"; then
			layer=adblock
			detail="DNS sink 0.0.0.0"
		fi
	fi

	route=direct
	route_detail="остальное → WAN"
	if ui_domain_in_list_suffix "$d" "$RVPN_RULES/games-domains.txt" || \
		ui_domain_in_list_suffix "$d" "$RVPN_GAMES_USER"; then
		route=games
		route_detail="DIRECT (games) + real DNS"
	elif ui_domain_in_list_suffix "$d" "$RVPN_RULES/vpn-domains.txt" || \
		ui_domain_in_list_suffix "$d" "$RVPN_USER_DOMAINS"; then
		route=vpn
		route_detail="FakeIP → VPN"
	elif ui_domain_in_list_suffix "$d" "$RVPN_RULES/dpi.txt" || \
		ui_domain_in_list_suffix "$d" "$RVPN_DPI_USER"; then
		route=zapret
		route_detail="DIRECT + nfqws DPI"
	fi

	if [ "$layer" = "adblock" ]; then
		printf '{"ok":1,"domain":"%s","layer":"adblock","detail":"%s","route":"%s","route_detail":"%s"}\n' \
			"$dj" "$(json_escape "$detail")" "$route" "$(json_escape "$route_detail")"
	else
		printf '{"ok":1,"domain":"%s","layer":"%s","detail":"%s","route":"%s","route_detail":"%s"}\n' \
			"$dj" "$route" "$(json_escape "$route_detail")" "$route" "$(json_escape "$route_detail")"
	fi
}

ui_matrix_json() {
	vpn_n=$(ui_count_lines "$RVPN_RULES/vpn-domains.txt")
	vpn_u=$(ui_count_lines "$RVPN_USER_DOMAINS")
	dpi_n=$(ui_count_lines "$RVPN_RULES/dpi.txt")
	dpi_u=$(ui_count_lines "$RVPN_DPI_USER")
	games_n=$(ui_count_lines "$RVPN_RULES/games-domains.txt")
	games_u=$(ui_count_lines "$RVPN_GAMES_USER")
	cidr_n=$(count_grep '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/' "$RVPN_RULES/vpn-cidr.txt")
	adb_n=0
	adb_upd=
	[ -f "$RVPN_RUN/adblock.meta" ] && {
		adb_n=$(sed -n 's/^domains=//p' "$RVPN_RUN/adblock.meta" | head -1)
		adb_upd=$(sed -n 's/^updated=//p' "$RVPN_RUN/adblock.meta" | head -1)
	}
	cidr_age=-1
	if [ -f "$RVPN_RULES/vpn-cidr.txt" ]; then
		now=$(date +%s 2>/dev/null || echo 0)
		mt=$(date -r "$RVPN_RULES/vpn-cidr.txt" +%s 2>/dev/null || echo 0)
		if [ "$now" -gt 0 ] && [ "$mt" -gt 0 ]; then
			cidr_age=$(( (now - mt) / 86400 ))
		fi
	fi
	adb_upd_j=$(json_escape "${adb_upd:-}")
	printf '{"ok":1,"vpn_shipped":%s,"vpn_user":%s,"dpi_shipped":%s,"dpi_user":%s,"games_shipped":%s,"games_user":%s,"cidr":%s,"cidr_age_days":%s,"adblock_domains":%s,"adblock_updated":"%s"}\n' \
		"${vpn_n:-0}" "${vpn_u:-0}" "${dpi_n:-0}" "${dpi_u:-0}" "${games_n:-0}" "${games_u:-0}" \
		"${cidr_n:-0}" "${cidr_age:--1}" "${adb_n:-0}" "$adb_upd_j"
}

# Cached nft table probe (~30s) — status+health share one check per poll window.
ui_nft_table_ok() {
	# $1 = table name under inet (rvpn_vpn / rvpn_zapret)
	tbl=$1
	c=$RVPN_RUN/nft.${tbl}.cache
	now=$(date +%s 2>/dev/null || echo 0)
	if [ -f "$c" ] && [ "$now" != 0 ]; then
		read -r ts val <<EOF
$(cat "$c" 2>/dev/null)
EOF
		case "$ts" in ''|*[!0-9]*) ;; *)
			age=$((now - ts))
			if [ "$age" -ge 0 ] && [ "$age" -lt 30 ]; then
				[ "$val" = "1" ]
				return $?
			fi
			;;
		esac
	fi
	ok=0
	nft list table inet "$tbl" >/dev/null 2>&1 && ok=1
	echo "$now $ok" >"$c" 2>/dev/null || true
	[ "$ok" = "1" ]
}

ui_dns_orphan() {
	# shellcheck source=/dev/null
	. /usr/lib/rvpn/dns.sh
	dns_uci_points_to_fakeip || return 1
	dns_vpn_ready && return 1
	return 0
}

ui_health_detail_json() {
	dns_mode=$(cat "$RVPN_RUN/dns.applied" 2>/dev/null || echo off)
	dns_j=$(json_escape "$dns_mode")
	nft_vpn=0
	ui_nft_table_ok rvpn_vpn && nft_vpn=1
	nft_zap=0
	ui_nft_table_ok rvpn_zapret && nft_zap=1
	wd=0
	if [ -f "$RVPN_WD_PID" ] && kill -0 "$(cat "$RVPN_WD_PID" 2>/dev/null)" 2>/dev/null; then
		wd=1
	fi
	sb=0
	sb_alive && sb=1
	nfq=0
	if [ -f "$RVPN_RUN/nfqws.pid" ] && kill -0 "$(cat "$RVPN_RUN/nfqws.pid" 2>/dev/null)" 2>/dev/null; then
		nfq=1
	elif pgrep -f '^/opt/rvpn/nfqws' >/dev/null 2>&1; then
		nfq=1
	fi
	fo=
	[ -f "$RVPN_LAST_FAILOPEN" ] && fo=$(cat "$RVPN_LAST_FAILOPEN" 2>/dev/null)
	fo_j=$(json_escape "${fo:-}")
	degraded=0
	vpn=$(uci_get vpn_enabled)
	if [ "$vpn" = "1" ] && [ "$sb" = "1" ]; then
		echo "$dns_mode" | grep -q fakeip || degraded=1
		[ "$nft_vpn" = "1" ] || degraded=1
	fi
	dns_orphan=0
	ui_dns_orphan && dns_orphan=1
	[ "$dns_orphan" = "1" ] && degraded=1
	failsafe_hold=0
	rvpn_failsafe_hold_active && failsafe_hold=1 && degraded=1
	corrupt_nodes=$(rvpn_corrupt_node_count)
	case "$corrupt_nodes" in ''|*[!0-9]*) corrupt_nodes=0 ;; esac
	printf '{"ok":1,"singbox":%s,"nfqws":%s,"dns_mode":"%s","nft_vpn":%s,"nft_zapret":%s,"watchdog":%s,"last_failopen":"%s","degraded":%s,"dns_orphan":%s,"failsafe_hold":%s,"corrupt_nodes":%s}\n' \
		"$sb" "$nfq" "$dns_j" "$nft_vpn" "$nft_zap" "$wd" "$fo_j" "$degraded" "$dns_orphan" "$failsafe_hold" "$corrupt_nodes"
}

# Emergency: restore DNS/nft, stop engines.
# soft — keep layer toggles but set failsafe.hold (no auto-start until Start)
# hard — turn VPN+zapret off and clear hold
ui_failsafe_run() {
	mode=${1:-hard}
	# shellcheck source=/dev/null
	. /usr/lib/rvpn/dns.sh
	# shellcheck source=/dev/null
	. /usr/lib/rvpn/nft.sh
	# shellcheck source=/dev/null
	. /usr/lib/rvpn/singbox.sh
	# shellcheck source=/dev/null
	. /usr/lib/rvpn/zapret.sh
	# shellcheck source=/dev/null
	. /usr/lib/rvpn/watchdog.sh

	log "FAILSAFE mode=$mode"
	watchdog_stop 2>/dev/null || true
	nft_flush_zapret 2>/dev/null || true
	nft_flush_vpn 2>/dev/null || true
	nft_flush_quic 2>/dev/null || true
	nft_flush_doh 2>/dev/null || true
	ip rule del fwmark 0x1 lookup 100 2>/dev/null || true
	ip route flush table 100 2>/dev/null || true
	zapret_stop 2>/dev/null || true
	sb_kill_ours 2>/dev/null || true
	rm -f "$RVPN_RUN/sing-box.pid" "$RVPN_RUN/nfqws.pid" 2>/dev/null || true
	dns_heal_orphan 2>/dev/null || true
	dns_restore 2>/dev/null || true
	adblock_apply 2>/dev/null || true
	if [ "$mode" = "hard" ]; then
		uci set rvpn.main.vpn_enabled='0'
		uci set rvpn.main.zapret_enabled='0'
		uci commit rvpn
		rvpn_failsafe_hold_clear
	else
		rvpn_failsafe_hold_set soft
	fi
	echo failsafe_hold >"$RVPN_STATE"
	[ "$mode" = "hard" ] && echo stopped >"$RVPN_STATE"
	date -u +%Y-%m-%dT%H:%MZ 2>/dev/null >"$RVPN_RUN/last_failopen" || date >"$RVPN_RUN/last_failopen"
	hold=0
	rvpn_failsafe_hold_active && hold=1
	log "FAILSAFE done mode=$mode hold=$hold"
	printf '{"ok":1,"mode":"%s","vpn_enabled":%s,"zapret_enabled":%s,"failsafe_hold":%s,"msg":"failsafe_done"}\n' \
		"$mode" "$(uci_get vpn_enabled)" "$(uci_get zapret_enabled)" "$hold"
}

ui_json_string_array_from_file() {
	file=$1
	[ -f "$file" ] || { echo -n '[]'; return 0; }
	# One-pass: strip comments/blank, JSON-escape, emit array
	awk '
		function esc(s,   t) {
			t = s
			gsub(/\\/, "\\\\", t)
			gsub(/"/, "\\\"", t)
			gsub(/\t/, "\\t", t)
			gsub(/\r/, "\\r", t)
			gsub(/\n/, "\\n", t)
			return t
		}
		{
			sub(/#.*/, "")
			gsub(/[[:space:]]/, "")
			if ($0 == "") next
			n++
			d[n] = $0
		}
		END {
			printf "["
			for (i = 1; i <= n; i++) {
				if (i > 1) printf ","
				printf "\"%s\"", esc(d[i])
			}
			printf "]"
		}
	' "$file"
}

ui_domains_json() {
	echo -n '{"ok":1,"user":'
	ui_json_string_array_from_file "$RVPN_USER_DOMAINS"
	echo -n ',"dpi_user":'
	ui_json_string_array_from_file "$RVPN_DPI_USER"
	echo -n ',"games_user":'
	ui_json_string_array_from_file "$RVPN_GAMES_USER"
	echo -n ',"adblock_allow":'
	ui_json_string_array_from_file "$RVPN_ADBLOCK_ALLOW"
	echo '}'
	echo
}

ui_domains_file_for_layer() {
	case "$1" in
	vpn|user) echo "$RVPN_USER_DOMAINS" ;;
	zapret|dpi) echo "$RVPN_DPI_USER" ;;
	games|direct) echo "$RVPN_GAMES_USER" ;;
	allow|adblock-allow) echo "$RVPN_ADBLOCK_ALLOW" ;;
	vpn-shipped|vpn_shipped) echo "$RVPN_RULES/vpn-domains.txt" ;;
	dpi-shipped|zapret-shipped|dpi_shipped) echo "$RVPN_RULES/dpi.txt" ;;
	games-shipped|games_shipped) echo "$RVPN_RULES/games-domains.txt" ;;
	*) return 1 ;;
	esac
}

ui_domains_text() {
	layer=$1
	f=$(ui_domains_file_for_layer "$layer") || {
		echo '{"error":"bad_layer"}'
		return 1
	}
	hdr="# User list ($layer). One domain per line."
	case "$layer" in
	vpn|user) hdr="# User VPN domains (quick-add / editor). Merged with vpn-domains.txt." ;;
	zapret|dpi) hdr="# User DPI hostlist. Merged with dpi.txt." ;;
	games|direct) hdr="# User games DIRECT. Merged with games-domains.txt." ;;
	allow|adblock-allow) hdr="# Adblock allowlist." ;;
	esac
	echo -n '{"ok":1,"layer":"'
	printf '%s' "$(json_escape "$layer")"
	echo -n '","text":"'
	{
		[ -f "$f" ] && list_domains "$f"
	} | awk 'BEGIN{first=1} NF{
		gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\r/,"");
		if(!first) printf "\\n"; first=0; printf "%s",$0
	}'
	echo '"}'
}

ui_domains_set() {
	layer=$1
	text=$2
	# Shipped base lists are read-only in UI — edit user overlays instead
	case "$layer" in
	vpn-shipped|vpn_shipped|dpi-shipped|zapret-shipped|dpi_shipped|games-shipped|games_shipped)
		printf '{"ok":0,"error":"shipped_readonly","hint":"use vpn / dpi / games user lists"}\n'
		return 1
		;;
	esac
	f=$(ui_domains_file_for_layer "$layer") || return 1
	mkdir -p "$(dirname "$f")" "$RVPN_RUN"
	tmp=$RVPN_RUN/domains-set.$$
	: >"$tmp"
	n=0
	# Accept newlines / commas / spaces
	printf '%s\n' "$text" | tr ',;' '\n\n' | while IFS= read -r line || [ -n "$line" ]; do
		line=$(printf '%s' "$line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
		[ -n "$line" ] || continue
		case "$line" in \#*) continue ;; esac
		d=$(normalize_domain "$line" 2>/dev/null) || continue
		valid_domain_token "$d" 2>/dev/null || continue
		printf '%s\n' "$d"
	done | awk 'NF && !seen[$0]++' >"$tmp"
	n=$(wc -l <"$tmp" | tr -d ' ')
	case "$n" in ''|*[!0-9]*) n=0 ;; esac
	hdr="# User list ($layer) — edited from UI."
	{
		echo "$hdr"
		cat "$tmp"
	} >"$f"
	rm -f "$tmp"
	chmod 644 "$f" 2>/dev/null || true
	case "$layer" in
	vpn|user|games|direct|vpn-shipped|vpn_shipped|games-shipped|games_shipped)
		. /usr/lib/rvpn/singbox.sh 2>/dev/null || true
		sb_reload_domains >/dev/null 2>&1 || true
		;;
	zapret|dpi|dpi-shipped|zapret-shipped|dpi_shipped)
		if [ "$(uci_get zapret_enabled)" = "1" ]; then
			rvpn_with_lock /bin/sh -c '. /usr/lib/rvpn/zapret.sh; zapret_start' >>"$RVPN_LOG" 2>&1 || true
		fi
		;;
	allow|adblock-allow)
		if [ "$(uci_get adblock_enabled)" = "1" ]; then
			. /usr/lib/rvpn/adblock.sh
			adblock_apply >/dev/null 2>&1 || true
		fi
		;;
	esac
	printf '{"ok":1,"layer":"%s","count":%s}\n' "$(json_escape "$layer")" "$n"
}

ui_vps_json() {
	server=$(uci -q get rvpn.vps_hy2.server)
	port=$(uci -q get rvpn.vps_hy2.port)
	password=$(uci -q get rvpn.vps_hy2.password)
	sni=$(uci -q get rvpn.vps_hy2.sni)
	insecure=$(uci -q get rvpn.vps_hy2.insecure)
	en=$(uci -q get rvpn.vps_hy2.enabled)
	tag=$(uci -q get rvpn.vps_hy2.tag)
	type=$(uci -q get rvpn.vps_hy2.type)
	vpn=$(uci_get vpn_enabled)
	case "$en" in 1) en=1 ;; *) en=0 ;; esac
	case "$insecure" in 1) insecure=1 ;; *) insecure=0 ;; esac
	case "$vpn" in 1) vpn=1 ;; *) vpn=0 ;; esac
	[ -n "$port" ] || port=433
	[ -n "$sni" ] || sni=bing.com
	[ -n "$type" ] || type=hysteria2
	[ -n "$tag" ] || tag=vps-fi-hy2
	pw_set=0
	[ -n "$password" ] && pw_set=1
	# Never return plaintext password to the browser
	printf '{"ok":1,"configured":%s,"enabled":%s,"vpn_enabled":%s,"tag":"%s","type":"%s","server":"%s","port":"%s","password_set":%s,"sni":"%s","insecure":%s}\n' \
		"$([ -n "$server" ] && echo 1 || echo 0)" \
		"$en" "$vpn" \
		"$(json_escape "$tag")" \
		"$(json_escape "$type")" \
		"$(json_escape "$server")" \
		"$(json_escape "$port")" \
		"$pw_set" \
		"$(json_escape "$sni")" \
		"$insecure"
}

ui_route_add() {
	layer=$1
	raw=$2
	d=
	case "$layer" in
	vpn)
		vpn_user_add "$raw" || return 1
		d=$(normalize_domain "$raw")
		sb_reload_domains >/dev/null 2>&1 || true
		;;
	zapret|dpi)
		d=$(ui_list_add "$RVPN_DPI_USER" "# User DPI hostlist (quick-add). Merged with dpi.txt." "$raw") || return 1
		# Restart zapret under service lock (serialize vs init.d restart)
		if [ "$(uci_get zapret_enabled)" = "1" ]; then
			rvpn_with_lock /bin/sh -c '
				. /usr/lib/rvpn/zapret.sh
				zapret_start
			' >>"$RVPN_LOG" 2>&1 || true
		fi
		;;
	games|direct)
		d=$(ui_list_add "$RVPN_GAMES_USER" "# User games DIRECT (quick-add). Merged with games-domains.txt." "$raw") || return 1
		sb_reload_domains >/dev/null 2>&1 || true
		;;
	allow|adblock-allow)
		d=$(ui_list_add "$RVPN_ADBLOCK_ALLOW" "# Allowlist — never block (exact or suffix match)." "$raw") || return 1
		if [ "$(uci_get adblock_enabled)" = "1" ]; then
			. /usr/lib/rvpn/adblock.sh
			adblock_apply >/dev/null 2>&1 || true
		fi
		;;
	*)
		return 1
		;;
	esac
	dj=$(json_escape "$d")
	lj=$(json_escape "$layer")
	printf '{"ok":1,"domain":"%s","layer":"%s"}\n' "$dj" "$lj"
}

ui_subs_json() {
	# shellcheck source=/dev/null
	. /usr/lib/rvpn/sub.sh
	echo -n '{"ok":1,"subs":['
	sep=
	for sid in $(sub_list_ids); do
		en=$(uci -q get "rvpn.$sid.enabled")
		url=$(uci -q get "rvpn.$sid.url")
		# Redact URL for UI: show scheme+host only
		url_show=
		if [ -n "$url" ]; then
			url_show=$(printf '%s' "$url" | sed -n 's|^\([a-zA-Z][a-zA-Z0-9+.-]*://[^/]*\).*|\1/…|p')
			[ -n "$url_show" ] || url_show='(set)'
		fi
		case "$en" in 1) en=1 ;; *) en=0 ;; esac
		cnt=$(uci -q get "rvpn.$sid.last_count")
		case "$cnt" in ''|*[!0-9]*) cnt=0 ;; esac
		last=$(uci -q get "rvpn.$sid.last_sync")
		hours=$(uci -q get "rvpn.$sid.refresh_hours")
		case "$hours" in ''|*[!0-9]*) hours=12 ;; esac
		age=$(sub_hours_since_sync "$sid" 2>/dev/null || echo -1)
		case "$age" in ''|*[!0-9-]*) age=-1 ;; esac
		printf '%s{"id":"%s","enabled":%s,"url_set":%s,"url_show":"%s","last_count":%s,"last_sync":"%s","refresh_hours":%s,"age_hours":%s}' \
			"$sep" \
			"$(json_escape "$sid")" \
			"$en" \
			"$([ -n "$url" ] && echo 1 || echo 0)" \
			"$(json_escape "$url_show")" \
			"$cnt" \
			"$(json_escape "${last:-}")" \
			"$hours" \
			"$age"
		sep=,
	done
	echo ']}'
	echo
}

ui_pool_json() {
	echo -n '{"ok":1,"nodes":['
	sep=
	delays=$RVPN_RUN/pool/delays.tsv
	uitmp=$RVPN_RUN/pool/ui.$$.tsv
	# Prefer last probe file; else list enabled UCI tags
	if [ -f "$delays" ] && [ -s "$delays" ]; then
		sort -t'	' -k1,1n "$delays" 2>/dev/null | while IFS='	' read -r delay tag id; do
			[ -n "$tag" ] || continue
			en=$(uci -q get "rvpn.$id.enabled")
			case "$en" in 1) en=1 ;; *) en=0 ;; esac
			case "$delay" in ''|*[!0-9]*) delay=0 ;; esac
			printf '%s\t%s\t%s\t%s\n' "$delay" "$tag" "$id" "$en"
		done >"$uitmp"
		while IFS='	' read -r delay tag id en; do
			[ -n "$tag" ] || continue
			printf '%s{"tag":"%s","id":"%s","delay_ms":%s,"enabled":%s}' \
				"$sep" "$(json_escape "$tag")" "$(json_escape "$id")" "${delay:-0}" "${en:-0}"
			sep=,
		done <"$uitmp"
		rm -f "$uitmp"
	else
		for id in $(uci -q show rvpn 2>/dev/null | sed -n 's/^rvpn\.\([^=]*\)=node$/\1/p'); do
			en=$(uci -q get "rvpn.$id.enabled")
			[ "$en" = "1" ] || continue
			tag=$(uci -q get "rvpn.$id.tag")
			[ -n "$tag" ] || tag=$id
			printf '%s{"tag":"%s","id":"%s","delay_ms":0,"enabled":1}' \
				"$sep" "$(json_escape "$tag")" "$(json_escape "$id")"
			sep=,
		done
	fi
	echo ']}'
	echo
}

ui_load_json() {
	f=$RVPN_LOAD_LOG
	[ -n "$f" ] || f=$RVPN_RUN/load-hourly.log
	echo -n '{"ok":1,"samples":['
	sep=
	loadtmp=$RVPN_RUN/load-ui.$$.jsonl
	tail -n 48 "$f" 2>/dev/null | while IFS= read -r line; do
		case "$line" in
		\#*) continue ;;
		esac
		# ts load_x100 mem_avail_kb mem_total_kb lan_clients wan_rx wan_tx vpn zap
		set -- $line
		[ -n "$2" ] || continue
		printf '{"ts":"%s","load_x100":%s,"lan":%s,"vpn":%s,"zap":%s}\n' \
			"$(json_escape "$1")" "${2:-0}" "${5:-0}" "${8:-0}" "${9:-0}"
	done >"$loadtmp"
	while IFS= read -r obj; do
		[ -n "$obj" ] || continue
		printf '%s%s' "$sep" "$obj"
		sep=,
	done <"$loadtmp"
	rm -f "$loadtmp"
	echo ']}'
	echo
}

# Single UI poll: status + health + matrix + domains + subs + pool + spark samples.
ui_snapshot_json() {
	st=$(health_status_json | head -1 | tr -d '\r')
	he=$(ui_health_detail_json | head -1 | tr -d '\r')
	mx=$(ui_matrix_json | head -1 | tr -d '\r')
	dom=$(ui_domains_json | head -1 | tr -d '\r')
	subs=$(ui_subs_json | head -1 | tr -d '\r')
	pool=$(ui_pool_json | head -1 | tr -d '\r')
	load=$(ui_load_json | head -1 | tr -d '\r')
	[ -n "$st" ] || st='{}'
	[ -n "$he" ] || he='{}'
	[ -n "$mx" ] || mx='{}'
	[ -n "$dom" ] || dom='{"ok":1,"user":[],"dpi_user":[],"games_user":[],"adblock_allow":[]}'
	[ -n "$subs" ] || subs='{"ok":1,"subs":[]}'
	[ -n "$pool" ] || pool='{"ok":1,"nodes":[]}'
	[ -n "$load" ] || load='{"ok":1,"samples":[]}'
	printf '{"ok":1,"status":%s,"health":%s,"matrix":%s,"domains":%s,"subs":%s,"pool":%s,"load":%s}\n' \
		"$st" "$he" "$mx" "$dom" "$subs" "$pool" "$load"
}

ui_preset_apply() {
	name=$1
	case "$name" in
	movie|кино)
		uci set rvpn.main.vpn_enabled='1'
		uci set rvpn.main.zapret_enabled='1'
		uci set rvpn.main.adblock_enabled='1'
		;;
	game|игры)
		uci set rvpn.main.vpn_enabled='1'
		uci set rvpn.main.zapret_enabled='1'
		uci set rvpn.main.adblock_enabled='0'
		;;
	minimal|минимум)
		uci set rvpn.main.vpn_enabled='0'
		uci set rvpn.main.zapret_enabled='0'
		uci set rvpn.main.adblock_enabled='1'
		;;
	full|полный)
		uci set rvpn.main.vpn_enabled='1'
		uci set rvpn.main.zapret_enabled='1'
		uci set rvpn.main.adblock_enabled='1'
		;;
	*)
		return 1
		;;
	esac
	uci commit rvpn
	nj=$(json_escape "$name")
	printf '{"ok":1,"preset":"%s","async":1,"zapret_enabled":%s,"vpn_enabled":%s,"adblock_enabled":%s}\n' \
		"$nj" "$(uci_get zapret_enabled)" "$(uci_get vpn_enabled)" "$(uci_get adblock_enabled)"
}

ui_wifi_qr_json() {
	iface=$(uci -q show wireless | sed -n 's/wireless\.\(.*\)=wifi-iface/\1/p' | while read -r i; do
		mode=$(uci -q get "wireless.$i.mode")
		if [ "$mode" = "ap" ]; then
			echo "$i"
			break
		fi
	done)
	
	if [ -z "$iface" ]; then
		echo '{"ok":0,"error":"no_ap"}'
		return 1
	fi
	
	ssid=$(uci -q get "wireless.$iface.ssid")
	key=$(uci -q get "wireless.$iface.key")
	enc=$(uci -q get "wireless.$iface.encryption")
	
	case "$enc" in
		*wep*) t="WEP" ;;
		none) t="nopass" ;;
		*) t="WPA" ;;
	esac
	
	esc_wifi() {
		echo "$1" | sed 's/\([\\;,:"]\)/\\\1/g'
	}
	
	ssid_esc=$(esc_wifi "$ssid")
	key_esc=$(esc_wifi "$key")
	
	payload="WIFI:T:${t};S:${ssid_esc};P:${key_esc};;"
	svg=
	if command -v qrencode >/dev/null 2>&1; then
		svg=$(printf '%s' "$payload" | qrencode -t SVG -o - 2>/dev/null | tr -d '\n\r')
	fi
	printf '{"ok":1,"ssid":"%s","key":"%s","encryption":"%s","payload":"%s","svg":"%s"}\n' \
		"$(json_escape "$ssid")" "$(json_escape "${key:-}")" "$(json_escape "$enc")" \
		"$(json_escape "$payload")" "$(json_escape "${svg:-}")"
}

ui_categories_json() {
	cat_file="$RVPN_RULES/categories.json"
	if [ ! -f "$cat_file" ]; then
		echo '{"ok":0,"error":"no_categories"}'
		return 1
	fi
	
	pending_sync=0
	{ [ -f "$RVPN_RUN/zapret_sync.pending" ] || [ -f "$RVPN_RUN/nfqws_fetch.pending" ]; } && pending_sync=1
	
	eval $(awk '
		/"id":/ {
			sub(/.*"id":[ \t]*"/, "")
			sub(/".*/, "")
			id = $0
			ids = ids " " id
		}
		/"sources":/ {
			s = $0
			sub(/.*"sources":[ \t]*\[/, "", s)
			sub(/\].*/, "", s)
			gsub(/"/, "", s)
			gsub(/,/, " ", s)
			print "cat_sources_" id "=\"" s "\""
		}
		END {
			print "cat_ids=\"" ids "\""
		}
	' "$cat_file")
	
	counts=""
	sep=""
	for id in $cat_ids; do
		eval "srcs=\$cat_sources_$id"
		total=0
		for src in $srcs; do
			path="$RVPN_RULES/../$src"
			if [ -f "$path" ]; then
				c=$(ui_count_lines "$path")
				total=$((total + c))
			fi
		done
		counts="${counts}${sep}\"${id}\":${total}"
		sep=","
	done
	
	cat_json=$(cat "$cat_file")
	printf '{"ok":1,"pending_sync":%s,"counts":{%s},"categories":%s}\n' \
		"$pending_sync" "$counts" "$cat_json"
}

ui_setup_status_json() {
	setup_done=$(uci_get setup_done)
	[ -z "$setup_done" ] && setup_done=0
	
	setup_step="start"
	[ -f "/tmp/rvpn/setup.state" ] && setup_step=$(cat "/tmp/rvpn/setup.state" 2>/dev/null)
	
	secrets_present=0
	if uci -q show rvpn | grep -q -E '\.(url|token|password|key)='; then
		secrets_present=1
	fi
	
	zapret_enabled=$(uci_get zapret_enabled)
	[ -z "$zapret_enabled" ] && zapret_enabled=0
	
	vpn_enabled=$(uci_get vpn_enabled)
	[ -z "$vpn_enabled" ] && vpn_enabled=0
	
	adblock_enabled=$(uci_get adblock_enabled)
	[ -z "$adblock_enabled" ] && adblock_enabled=0
	
	pending_sync=0
	{ [ -f "$RVPN_RUN/zapret_sync.pending" ] || [ -f "$RVPN_RUN/nfqws_fetch.pending" ]; } && pending_sync=1
	warn=
	[ -f "$RVPN_RUN/zapret_sync.warn" ] && warn=$(cat "$RVPN_RUN/zapret_sync.warn" 2>/dev/null)
	
	printf '{"ok":1,"setup_done":%s,"setup_step":"%s","secrets_present":%s,"zapret_enabled":%s,"vpn_enabled":%s,"adblock_enabled":%s,"pending_sync":%s,"warn":"%s"}\n' \
		"$setup_done" "$(json_escape "$setup_step")" "$secrets_present" "$zapret_enabled" "$vpn_enabled" "$adblock_enabled" "$pending_sync" "$(json_escape "${warn:-}")"
}

ui_setup_done_set() {
	uci set rvpn.main.setup_done=1
	uci commit rvpn
	echo '{"ok":1}'
}
