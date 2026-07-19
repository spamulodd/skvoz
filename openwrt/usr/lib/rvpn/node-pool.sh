#!/bin/sh
# Node pool: Clash API delay probes → enable best / disable dead / fallback floor.
# Inspired by conflux urltest+prefer pipeline; works on UCI nodes already imported.
. /usr/lib/rvpn/common.sh
. /usr/lib/rvpn/health.sh

POOL_DIR=$RVPN_RUN/pool

# URL-encode path segment for Clash API proxy name (BusyBox-safe subset).
pool_urlencode() {
	printf '%s' "$1" | awk '
		BEGIN {
			for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i
		}
		{
			n = length($0)
			for (i = 1; i <= n; i++) {
				c = substr($0, i, 1)
				if (c ~ /[A-Za-z0-9._~-]/) printf "%s", c
				else printf "%%%02X", ord[c]
			}
		}'
}

pool_probe_timeout_ms() {
	t=$(uci_get pool_probe_timeout_ms)
	[ -n "$t" ] || t=5000
	case "$t" in ''|*[!0-9]*) t=5000 ;; esac
	[ "$t" -ge 1000 ] || t=1000
	[ "$t" -le 30000 ] || t=30000
	echo "$t"
}

pool_keep() {
	k=$(uci_get pool_keep)
	[ -n "$k" ] || k=6
	case "$k" in ''|*[!0-9]*) k=6 ;; esac
	[ "$k" -ge 1 ] || k=1
	echo "$k"
}

pool_min_alive() {
	m=$(uci_get pool_min_alive)
	[ -n "$m" ] || m=2
	case "$m" in ''|*[!0-9]*) m=2 ;; esac
	[ "$m" -ge 1 ] || m=1
	echo "$m"
}

# Probe one outbound tag. Prints delay ms (0 = fail).
pool_probe_tag() {
	tag=$1
	api=$(clash_api_local)
	url=$(uci_get urltest_url)
	[ -n "$url" ] || url=https://www.gstatic.com/generate_204
	timeout=$(pool_probe_timeout_ms)
	enc=$(pool_urlencode "$tag")
	body=$(curl -sS --connect-timeout 2 --max-time $((timeout / 1000 + 3)) \
		-H "$(clash_auth_hdr)" \
		"http://${api}/proxies/${enc}/delay?url=$(pool_urlencode "$url")&timeout=${timeout}" 2>/dev/null) || {
		echo 0
		return 1
	}
	delay=$(echo "$body" | sed -n 's/.*"delay"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
	case "$delay" in
	''|*[!0-9]*|0) echo 0; return 1 ;;
	*) echo "$delay"; return 0 ;;
	esac
}

# List UCI node section ids that are candidates (enabled or previously pool-managed).
pool_list_node_ids() {
	uci -q show rvpn | sed -n 's/^rvpn\.\([^=]*\)=node$/\1/p'
}

# Probe all currently enabled nodes → $POOL_DIR/delays.tsv (delay tag id)
# Also probes disabled nodes with source=sub:* so dead ones can recover.
pool_probe_all() {
	mkdir -p "$POOL_DIR"
	out=$POOL_DIR/delays.tsv
	: >"$out"
	vpn=$(uci_get vpn_enabled)
	if [ "$vpn" != "1" ] || [ -z "$(sb_pids)" ]; then
		log "pool: sing-box not running — skip probe"
		return 1
	fi
	n=0
	ok=0
	for id in $(pool_list_node_ids); do
		en=$(uci -q get "rvpn.$id.enabled")
		src=$(uci -q get "rvpn.$id.source")
		# Probe enabled always; also disabled sub: nodes for recovery
		case "$en" in
		1) ;;
		*)
			case "$src" in
			sub:*) ;;
			*) continue ;;
			esac
			;;
		esac
		tag=$(uci -q get "rvpn.$id.tag")
		[ -n "$tag" ] || tag="$id"
		delay=$(pool_probe_tag "$tag")
		printf '%s\t%s\t%s\n' "${delay:-0}" "$tag" "$id" >>"$out"
		n=$((n + 1))
		[ "${delay:-0}" -gt 0 ] 2>/dev/null && ok=$((ok + 1))
	done
	log "pool: probed $n nodes, alive=$ok"
	[ -s "$out" ]
}

# Enable/disable UCI nodes from delays.tsv using keep/min_alive/fallback.
pool_optimize() {
	keep=$(pool_keep)
	min=$(pool_min_alive)
	delays=$POOL_DIR/delays.tsv
	[ -f "$delays" ] || { pool_probe_all || return 1; }

	alive=$POOL_DIR/alive.tsv
	dead=$POOL_DIR/dead.tsv
	awk -F '\t' '$1+0 > 0 { print }' "$delays" | sort -t "$(printf '\t')" -k1,1n >"$alive"
	awk -F '\t' '$1+0 == 0 { print }' "$delays" >"$dead"

	alive_n=$(wc -l <"$alive" 2>/dev/null | tr -d ' ')
	[ -n "$alive_n" ] || alive_n=0

	# Fallback: if fewer than min_alive, re-enable prefer-ranked nodes by priority
	if [ "$alive_n" -lt "$min" ]; then
		log "pool: alive=$alive_n < min_alive=$min — fallback enable by priority"
		cand=$POOL_DIR/fallback.ids
		: >"$cand"
		for id in $(pool_list_node_ids); do
			pri=$(uci -q get "rvpn.$id.priority")
			case "$pri" in ''|*[!0-9]*) pri=99 ;; esac
			printf '%02d\t%s\n' "$pri" "$id" >>"$cand"
		done
		sort -t "$(printf '\t')" -k1,1n "$cand" | cut -f2 | head -n "$keep" >"$POOL_DIR/fallback.sel"
		while read -r id; do
			[ -n "$id" ] || continue
			uci -q set "rvpn.$id.enabled=1"
		done <"$POOL_DIR/fallback.sel"
		uci commit rvpn
		log "pool: fallback enabled top $keep by priority — restart VPN to apply"
		echo "# fallback by priority (id)"
		cat "$POOL_DIR/fallback.sel"
		return 0
	fi

	# Enable top `keep` alive; disable the rest of probed set
	sel=$POOL_DIR/selected.ids
	head -n "$keep" "$alive" | cut -f3 >"$sel"

	changed=0
	while IFS="$(printf '\t')" read -r delay tag id; do
		[ -n "$id" ] || continue
		if grep -qxF "$id" "$sel" 2>/dev/null; then
			cur=$(uci -q get "rvpn.$id.enabled")
			if [ "$cur" != "1" ]; then
				uci -q set "rvpn.$id.enabled=1"
				changed=1
			fi
		else
			cur=$(uci -q get "rvpn.$id.enabled")
			if [ "$cur" = "1" ]; then
				uci -q set "rvpn.$id.enabled=0"
				changed=1
			fi
		fi
	done <"$delays"

	if [ "$changed" = 1 ]; then
		uci commit rvpn
		log "pool: optimized — keep=$keep alive=$alive_n (UCI updated)"
	else
		log "pool: optimize noop — keep=$keep alive=$alive_n"
	fi

	echo "# delay_ms tag id"
	head -n "$keep" "$alive"
}

# Full: probe → optimize. Does not restart sing-box (caller may).
pool_run() {
	pool_probe_all || return 1
	pool_optimize
}
