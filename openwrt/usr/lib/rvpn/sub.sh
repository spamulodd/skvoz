#!/bin/sh
# Subscription module (conflux-inspired): fetch → parse → filter → UCI nodes.
# Supports Clash Meta YAML (primary) and Base64/plaintext URI lists (vless/hy2/trojan/ss).
. /usr/lib/rvpn/common.sh

RVPN_SUB_DIR=$RVPN_RUN/sub
CLASH_AWK=/usr/lib/rvpn/clash-parse.awk

sub_list_ids() {
	uci -q show rvpn | sed -n 's/^rvpn\.\([^=]*\)=subscription$/\1/p'
}

sub_fetch() {
	sid=$1
	url=$(uci -q get "rvpn.$sid.url")
	[ -n "$url" ] || { log "sub $sid: empty url"; return 1; }
	ua=$(uci -q get "rvpn.$sid.ua")
	[ -n "$ua" ] || ua='clash.meta'
	mkdir -p "$RVPN_SUB_DIR"
	out=$RVPN_SUB_DIR/$sid.raw
	hdr=$RVPN_SUB_DIR/$sid.hdr
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --connect-timeout 20 --max-time 120 \
			-A "$ua" -D "$hdr" "$url" -o "$out" || return 1
	elif command -v wget >/dev/null 2>&1; then
		wget -qT 120 -U "$ua" -O "$out" "$url" || return 1
		: >"$hdr"
	else
		log "sub: need curl or wget"
		return 1
	fi
	[ -s "$out" ] || return 1
	# HTML error page
	if head -c 64 "$out" | grep -qiE '<!doctype|<html'; then
		log "sub $sid: HTML body (auth/error page)"
		return 1
	fi
	# Persist update interval from headers if present
	iv=$(sed -n 's/[Pp]rofile-[Uu]pdate-[Ii]nterval:[[:space:]]*//p' "$hdr" 2>/dev/null | head -1 | tr -d '\r')
	case "$iv" in
	''|*[!0-9]*) ;;
	*)
		# header is hours if < 3600, else seconds
		if [ "$iv" -ge 3600 ]; then
			hours=$((iv / 3600))
		else
			hours=$iv
		fi
		[ "$hours" -ge 1 ] || hours=1
		uci -q set "rvpn.$sid.refresh_hours=$hours"
		;;
	esac
	echo "$out"
}

# Expand body to plaintext URI lines or Clash YAML path.
sub_expand() {
	raw=$1
	expanded=$2
	# Clash YAML?
	if grep -qE '^proxies:|^mixed-port:|^proxy-groups:' "$raw" 2>/dev/null; then
		cp -f "$raw" "$expanded"
		echo clash
		return 0
	fi
	# Base64 URI list?
	body=$(tr -d '\r\n' <"$raw")
	case "$body" in
	*[!A-Za-z0-9+/=_-]*)
		# plaintext URIs?
		if grep -qE '^(vless|vmess|ss|trojan|hysteria2|hy2)://' "$raw" 2>/dev/null; then
			cp -f "$raw" "$expanded"
			echo uri
			return 0
		fi
		log "sub: unknown format"
		return 1
		;;
	esac
	if echo "$body" | base64 -d >"$expanded" 2>/dev/null; then
		if grep -qE '^(vless|vmess|ss|trojan|hysteria2|hy2)://' "$expanded" 2>/dev/null; then
			echo uri
			return 0
		fi
	fi
	log "sub: base64 decode produced no URIs"
	return 1
}

# Minimal URI → TSV (subset). Clash path preferred for OverSecure-like panels.
sub_parse_uri_file() {
	infile=$1
	outfile=$2
	: >"$outfile"
	while IFS= read -r line || [ -n "$line" ]; do
		line=$(printf '%s' "$line" | tr -d '\r')
		[ -n "$line" ] || continue
		case "$line" in \#*) continue ;; esac
		scheme=${line%%://*}
		rest=${line#*://}
		frag=${rest#*#}
		[ "$frag" = "$rest" ] && frag=""
		main=${rest%%#*}
		case "$scheme" in
		hy2) scheme=hysteria2 ;;
		esac
		case "$scheme" in
		hysteria2)
			user=${main%%@*}
			hostport=${main#*@}
			hostport=${hostport%%/*}
			hostport=${hostport%%\?*}
			server=${hostport%%:*}
			port=${hostport##*:}
			# query
			q=${main#*\?}
			[ "$q" = "$main" ] && q=""
			q=${q%%#*}
			sni=$(echo "$q" | tr '&' '\n' | sed -n 's/^sni=//p' | head -1)
			ins=$(echo "$q" | tr '&' '\n' | sed -n 's/^insecure=//p' | head -1)
			tag=$(printf '%s' "$frag" | sed 's/[^A-Za-z0-9._-]/-/g' | cut -c1-40)
			[ -n "$tag" ] || tag="hy2-$server-$port"
			printf '%s\thysteria2\t%s\t%s\t\t%s\t%s\t\t\t\t\ttcp\t\t\t\n' \
				"$tag" "$server" "$port" "$user" "$sni" >>"$outfile"
			;;
		vless)
			# uuid@host:port?query#tag
			user=${main%%@*}
			hostport=${main#*@}
			hostport=${hostport%%\?*}
			server=${hostport%%:*}
			port=${hostport##*:}
			q=${main#*\?}
			[ "$q" = "$main" ] && q=""
			q=${q%%#*}
			sni=$(echo "$q" | tr '&' '\n' | sed -n 's/^sni=//p;s/^servername=//p' | head -1)
			pbk=$(echo "$q" | tr '&' '\n' | sed -n 's/^pbk=//p' | head -1)
			sid=$(echo "$q" | tr '&' '\n' | sed -n 's/^sid=//p' | head -1)
			flow=$(echo "$q" | tr '&' '\n' | sed -n 's/^flow=//p' | head -1)
			fp=$(echo "$q" | tr '&' '\n' | sed -n 's/^fp=//p' | head -1)
			net=$(echo "$q" | tr '&' '\n' | sed -n 's/^type=//p' | head -1)
			[ -n "$net" ] || net=tcp
			path=$(echo "$q" | tr '&' '\n' | sed -n 's/^path=//p' | head -1 | sed 's|%2F|/|g')
			host=$(echo "$q" | tr '&' '\n' | sed -n 's/^host=//p' | head -1)
			tag=$(printf '%s' "$frag" | sed 's/[^A-Za-z0-9._-]/-/g' | cut -c1-40)
			[ -n "$tag" ] || tag="vless-$server-$port"
			printf '%s\tvless\t%s\t%s\t%s\t\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t\n' \
				"$tag" "$server" "$port" "$user" "$sni" "$pbk" "$sid" "$flow" "$fp" "$net" "$path" "$host" >>"$outfile"
			;;
		trojan)
			user=${main%%@*}
			hostport=${main#*@}
			hostport=${hostport%%\?*}
			server=${hostport%%:*}
			port=${hostport##*:}
			q=${main#*\?}
			[ "$q" = "$main" ] && q=""
			q=${q%%#*}
			sni=$(echo "$q" | tr '&' '\n' | sed -n 's/^sni=//p' | head -1)
			fp=$(echo "$q" | tr '&' '\n' | sed -n 's/^fp=//p' | head -1)
			net=$(echo "$q" | tr '&' '\n' | sed -n 's/^type=//p' | head -1)
			[ -n "$net" ] || net=tcp
			path=$(echo "$q" | tr '&' '\n' | sed -n 's/^path=//p' | head -1 | sed 's|%2F|/|g')
			host=$(echo "$q" | tr '&' '\n' | sed -n 's/^host=//p' | head -1)
			tag=$(printf '%s' "$frag" | sed 's/[^A-Za-z0-9._-]/-/g' | cut -c1-40)
			[ -n "$tag" ] || tag="trojan-$server-$port"
			printf '%s\ttrojan\t%s\t%s\t\t%s\t%s\t\t\t\t%s\t%s\t%s\t%s\t\n' \
				"$tag" "$server" "$port" "$user" "$sni" "$fp" "$net" "$path" "$host" >>"$outfile"
			;;
		ss)
			# SIP002: ss://BASE64(method:pass)@host:port#tag  or  ss://method:pass@host:port
			userpart=${main%%@*}
			hostport=${main#*@}
			hostport=${hostport%%\?*}
			hostport=${hostport%%#*}
			server=${hostport%%:*}
			port=${hostport##*:}
			decoded=
			if echo "$userpart" | grep -q ':'; then
				decoded=$userpart
			else
				decoded=$(echo "$userpart" | base64 -d 2>/dev/null) || decoded=
			fi
			method=${decoded%%:*}
			password=${decoded#*:}
			tag=$(printf '%s' "$frag" | sed 's/[^A-Za-z0-9._-]/-/g' | cut -c1-40)
			[ -n "$tag" ] || tag="ss-$server-$port"
			printf '%s\tss\t%s\t%s\t\t%s\t\t\t\t\t\ttcp\t\t\t%s\n' \
				"$tag" "$server" "$port" "$password" "$method" >>"$outfile"
			;;
		esac
	done <"$infile"
}

sub_parse() {
	sid=$1
	raw=$2
	fmt_file=$RVPN_SUB_DIR/$sid.fmt
	exp=$RVPN_SUB_DIR/$sid.exp
	tsv=$RVPN_SUB_DIR/$sid.tsv
	fmt=$(sub_expand "$raw" "$exp") || return 1
	echo "$fmt" >"$fmt_file"
	case "$fmt" in
	clash)
		[ -f "$CLASH_AWK" ] || { log "missing $CLASH_AWK"; return 1; }
		awk -f "$CLASH_AWK" "$exp" >"$tsv" || return 1
		;;
	uri)
		sub_parse_uri_file "$exp" "$tsv" || return 1
		;;
	*)
		return 1
		;;
	esac
	[ -s "$tsv" ] || { log "sub $sid: zero nodes after parse"; return 1; }
	echo "$tsv"
}

# Prefer list: comma-separated protocol tokens ranked left→right.
# Tokens: vless-reality, vless-ws, vless-grpc, vless, hysteria2, trojan, ss
sub_node_rank() {
	type=$1
	network=$2
	pbk=$3
	prefer=$4
	[ -n "$prefer" ] || prefer='vless-reality,hysteria2,trojan,vless-ws,vless-grpc,vless,ss'
	token=
	case "$type" in
	hysteria2|hy2) token=hysteria2 ;;
	trojan) token=trojan ;;
	ss|shadowsocks) token=ss ;;
	vless)
		if [ -n "$pbk" ]; then
			token=vless-reality
		else
			case "$network" in
			ws) token=vless-ws ;;
			grpc) token=vless-grpc ;;
			*) token=vless ;;
			esac
		fi
		;;
	*) token=other ;;
	esac
	idx=0
	oldifs=$IFS
	IFS=,
	for p in $prefer; do
		idx=$((idx + 1))
		if [ "$p" = "$token" ]; then
			IFS=$oldifs
			echo "$idx"
			return 0
		fi
	done
	IFS=$oldifs
	echo 99
}

sub_filter_tsv() {
	sid=$1
	infile=$2
	outfile=$3
	max=$(uci -q get "rvpn.$sid.max_nodes")
	[ -n "$max" ] || max=24
	case "$max" in ''|*[!0-9]*) max=24 ;; esac
	prefer=$(uci -q get "rvpn.$sid.prefer")
	skip=$(uci -q get "rvpn.$sid.skip_keywords")
	[ -n "$skip" ] || skip='expire,剩余,流量,官网,套餐'

	: >"$outfile.ranked"
	while IFS="$(printf '\t')" read -r tag type server port uuid password sni pbk sid_r flow fp network path host method; do
		[ -n "$tag" ] || continue
		# keyword skip on tag
		bad=0
		oldifs=$IFS
		IFS=,
		for kw in $skip; do
			kw=$(echo "$kw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
			[ -n "$kw" ] || continue
			echo "$tag" | grep -qiF "$kw" && bad=1 && break
		done
		IFS=$oldifs
		[ "$bad" = 1 ] && continue
		rank=$(sub_node_rank "$type" "$network" "$pbk" "$prefer")
		printf '%02d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$rank" "$tag" "$type" "$server" "$port" "$uuid" "$password" "$sni" "$pbk" "$sid_r" "$flow" "$fp" "$network" "$path" "$host" "$method" \
			>>"$outfile.ranked"
	done <"$infile"

	sort -t "$(printf '\t')" -k1,1n -k3,3 -k4,4 "$outfile.ranked" | head -n "$max" | cut -f2- >"$outfile"
	rm -f "$outfile.ranked"
	[ -s "$outfile" ]
}

sub_uci_clear_source() {
	sid=$1
	src="sub:$sid"
	for id in $(uci -q show rvpn | sed -n 's/^rvpn\.\([^=]*\)=node$/\1/p'); do
		s=$(uci -q get "rvpn.$id.source")
		[ "$s" = "$src" ] || continue
		uci -q delete "rvpn.$id"
	done
}

# Sanitize UCI section id
sub_uci_id() {
	sid=$1
	tag=$2
	# uci section: [a-zA-Z0-9_]
	t=$(printf '%s' "$tag" | tr -c 'A-Za-z0-9_' '_' | cut -c1-48)
	echo "s_${sid}_$t"
}

sub_uci_import_tsv() {
	sid=$1
	tsv=$2
	src="sub:$sid"
	sub_uci_clear_source "$sid"
	n=0
	while IFS="$(printf '\t')" read -r tag type server port uuid password sni pbk sid_r flow fp network path host method; do
		[ -n "$tag" ] || continue
		case "$type" in
		hy2) type=hysteria2 ;;
		shadowsocks) type=ss ;;
		esac
		id=$(sub_uci_id "$sid" "$tag")
		# ensure unique if collision
		c=0
		while uci -q get "rvpn.$id" >/dev/null 2>&1; do
			c=$((c + 1))
			id=$(sub_uci_id "$sid" "${tag}_$c")
		done
		uci set "rvpn.$id=node"
		uci set "rvpn.$id.enabled=1"
		uci set "rvpn.$id.tag=$tag"
		uci set "rvpn.$id.type=$type"
		uci set "rvpn.$id.server=$server"
		uci set "rvpn.$id.port=$port"
		uci set "rvpn.$id.source=$src"
		uci set "rvpn.$id.network=${network:-tcp}"
		[ -n "$uuid" ] && uci set "rvpn.$id.uuid=$uuid"
		[ -n "$password" ] && uci set "rvpn.$id.password=$password"
		[ -n "$sni" ] && uci set "rvpn.$id.sni=$sni"
		[ -n "$pbk" ] && uci set "rvpn.$id.reality_public_key=$pbk"
		[ -n "$sid_r" ] && uci set "rvpn.$id.reality_short_id=$sid_r"
		[ -n "$flow" ] && uci set "rvpn.$id.flow=$flow"
		[ -n "$fp" ] && uci set "rvpn.$id.fingerprint=$fp"
		[ -n "$path" ] && uci set "rvpn.$id.path=$path"
		[ -n "$host" ] && uci set "rvpn.$id.host=$host"
		[ -n "$method" ] && uci set "rvpn.$id.method=$method"
		uci set "rvpn.$id.priority=$n"
		n=$((n + 1))
	done <"$tsv"
	uci set "rvpn.$sid.last_sync=$(date -u +%Y-%m-%dT%H:%MZ 2>/dev/null || date)"
	uci set "rvpn.$sid.last_count=$n"
	uci commit rvpn
	log "sub $sid: imported $n nodes"
	echo "$n"
}

# Full refresh one subscription → UCI (does not restart VPN).
sub_refresh() {
	sid=$1
	[ -n "$sid" ] || return 1
	en=$(uci -q get "rvpn.$sid.enabled")
	[ "$en" = "1" ] || { log "sub $sid: disabled"; return 0; }
	raw=$(sub_fetch "$sid") || return 1
	tsv=$(sub_parse "$sid" "$raw") || return 1
	filtered=$RVPN_SUB_DIR/$sid.filtered.tsv
	sub_filter_tsv "$sid" "$tsv" "$filtered" || return 1
	sub_uci_import_tsv "$sid" "$filtered"
}

sub_refresh_all() {
	ok=0
	for sid in $(sub_list_ids); do
		if sub_refresh "$sid"; then
			ok=$((ok + 1))
		else
			log "sub $sid: refresh failed"
		fi
	done
	[ "$ok" -gt 0 ]
}

# Hours since last_sync (UTC-ish). Empty last_sync → due.
sub_hours_since_sync() {
	sid=$1
	last=$(uci -q get "rvpn.$sid.last_sync")
	[ -n "$last" ] || { echo 9999; return 0; }
	# last_sync like 2026-07-18T12:00Z — BusyBox date -d may be missing; use file mtime fallback
	raw=$RVPN_SUB_DIR/$sid.raw
	if [ -f "$raw" ]; then
		# age in seconds via ls? prefer awk on epoch if available
		now=$(date +%s 2>/dev/null) || now=0
		mtime=$(date -r "$raw" +%s 2>/dev/null) || mtime=0
		if [ "$now" -gt 0 ] && [ "$mtime" -gt 0 ]; then
			echo $(((now - mtime) / 3600))
			return 0
		fi
	fi
	echo 9999
}

# Cron tick: refresh enabled subs whose refresh_hours elapsed.
sub_cron_tick() {
	for sid in $(sub_list_ids); do
		en=$(uci -q get "rvpn.$sid.enabled")
		[ "$en" = "1" ] || continue
		url=$(uci -q get "rvpn.$sid.url")
		[ -n "$url" ] || continue
		hours=$(uci -q get "rvpn.$sid.refresh_hours")
		[ -n "$hours" ] || hours=12
		case "$hours" in ''|*[!0-9]*) hours=12 ;; esac
		[ "$hours" -ge 1 ] || hours=1
		age=$(sub_hours_since_sync "$sid")
		if [ "$age" -ge "$hours" ]; then
			log "sub cron: refreshing $sid (age=${age}h >= ${hours}h)"
			sub_refresh "$sid" || log "sub cron: $sid failed"
		fi
	done
}
