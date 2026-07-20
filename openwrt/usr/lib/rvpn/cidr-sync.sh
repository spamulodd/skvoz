#!/bin/sh
# On-router refresh of vpn-cidr.txt + apply nft/sing-box.
# Sources match tools/sync-vpn-cidr.sh (Telegram official + ipverse ASN).
. /usr/lib/rvpn/common.sh
. /usr/lib/rvpn/nft.sh
. /usr/lib/rvpn/singbox.sh

RVPN_CIDR=$RVPN_RULES/vpn-cidr.txt
ASN_IP_BASE="${ASN_IP_BASE:-https://raw.githubusercontent.com/ipverse/asn-ip/master/as}"
TELEGRAM_CIDR_URL="${TELEGRAM_CIDR_URL:-https://core.telegram.org/resources/cidr.txt}"

cidr_fetch() {
	url=$1
	dest=$2
	if command -v curl >/dev/null 2>&1; then
		rvpn_curl -fsSL --connect-timeout 20 --max-time 120 "$url" -o "$dest"
	elif command -v wget >/dev/null 2>&1; then
		wget -qT 120 -O "$dest" "$url"
	else
		log "cidr-sync: need curl or wget"
		return 1
	fi
}

cidr_filter_v4() {
	awk '
		/^[[:space:]]*#/ { next }
		/^[[:space:]]*$/ { next }
		/:/{ next }
		{
			gsub(/[[:space:]]/, "")
			if ($0 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/) print $0
		}
	' | sort -u
}

cidr_fetch_asn() {
	asn=$1
	out=$2
	tmp=$RVPN_RUN/cidr-as$asn.txt
	if cidr_fetch "$ASN_IP_BASE/$asn/ipv4-aggregated.txt" "$tmp"; then
		cidr_filter_v4 <"$tmp" >"$out"
		[ -s "$out" ]
		return $?
	fi
	return 1
}

# Build new list into $1
cidr_sync_build() {
	dest=$1
	mkdir -p "$RVPN_RUN"
	work=$RVPN_RUN/cidr-sync-work
	rm -rf "$work"
	mkdir -p "$work"

	# Prefer previous sections as fallback when upstream blocked from RU.
	prev_section() {
		label=$1
		[ -f "$RVPN_CIDR" ] || return 0
		awk -v lab="$label" '
			BEGIN { k=0 }
			index($0, lab) == 1 { k=1; next }
			/^# --- / { if (k) exit }
			k && /^[0-9]/ { print }
		' "$RVPN_CIDR"
	}

	: >"$work/tg.v4"
	if cidr_fetch "$TELEGRAM_CIDR_URL" "$work/tg-raw.txt"; then
		cidr_filter_v4 <"$work/tg-raw.txt" >"$work/tg.v4"
	fi
	if [ ! -s "$work/tg.v4" ]; then
		prev_section "# --- Telegram (official)" >"$work/tg.v4"
		log "cidr-sync: telegram.org unreachable — kept previous official block"
	fi

	: >"$work/tg-extra.v4"
	for asn in 62041 62014 59930 44907 211157; do
		if cidr_fetch_asn "$asn" "$work/as$asn.v4"; then
			cat "$work/as$asn.v4" >>"$work/tg-extra.v4"
		fi
	done
	{
		cat "$work/tg-extra.v4"
		echo "95.161.64.0/20"
		prev_section "# --- Telegram (ASN"
	} | cidr_filter_v4 >"$work/tg-extra.sorted"

	cidr_fetch_asn 32934 "$work/as32934.v4" || true
	cidr_fetch_asn 13414 "$work/as13414.v4" || true
	cidr_fetch_asn 49544 "$work/as49544.v4" || true
	[ -s "$work/as32934.v4" ] || prev_section "# --- Meta" >"$work/as32934.v4"
	[ -s "$work/as13414.v4" ] || prev_section "# --- Twitter" >"$work/as13414.v4"
	[ -s "$work/as49544.v4" ] || prev_section "# --- Discord" >"$work/as49544.v4"

	# Need at least Telegram + something; abort only if almost empty
	tg_n=$(wc -l <"$work/tg.v4" | tr -d ' ')
	if [ "${tg_n:-0}" -lt 1 ] && [ ! -s "$work/as32934.v4" ]; then
		log "cidr-sync: no usable sources"
		rm -rf "$work"
		return 1
	fi

	ts=$(date -u +%Y-%m-%dT%H:%MZ 2>/dev/null || date)
	{
		echo "# VPN by IP (app connects to DC/CDN by address, not only DNS)."
		echo "# Auto-generated: $ts via rvpn cidr-sync"
		echo "# Sources: telegram.org/resources/cidr.txt + ipverse ASN aggregates"
		echo "#"
		echo "# --- Telegram (official) ---"
		cat "$work/tg.v4"
		echo "# --- Telegram (ASN / BGP extras) ---"
		cat "$work/tg-extra.sorted"
		echo "# --- Meta / Facebook / Instagram / WhatsApp (AS32934) ---"
		cat "$work/as32934.v4"
		echo "# --- Twitter / X (AS13414) ---"
		cat "$work/as13414.v4"
		echo "# --- Discord voice / RTC (AS49544 i3D; CF edge stays on domains) ---"
		cat "$work/as49544.v4"
	} >"$dest"
	rm -rf "$work"
	return 0
}

cidr_sync_apply() {
	# sb_reload_domains re-applies nft vpn — avoid double nft_apply_vpn
	vpn=$(uci_get vpn_enabled)
	zap=$(uci_get zapret_enabled)
	if [ "$vpn" = "1" ]; then
		sb_reload_domains || log "WARN: sing-box reload after cidr-sync"
		nft_apply_quic || true
	fi
	if [ "$zap" = "1" ]; then
		nft_apply_zapret || log "WARN: nft zapret after cidr-sync"
	fi
}

# Full sync: download → replace list → apply. Returns 0 on success.
cidr_sync_run() {
	mkdir -p "$RVPN_RUN" "$(dirname "$RVPN_CIDR")"
	tmp=$RVPN_RUN/vpn-cidr.new
	if ! cidr_sync_build "$tmp"; then
		log "cidr-sync: build failed — keeping previous list"
		rm -f "$tmp"
		return 1
	fi
	n=$(grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$tmp" | wc -l | tr -d ' ')
	if [ "${n:-0}" -lt 10 ]; then
		log "cidr-sync: suspiciously small list ($n) — abort"
		rm -f "$tmp"
		return 1
	fi
	cp -f "$RVPN_CIDR" "$RVPN_RUN/vpn-cidr.bak" 2>/dev/null || true
	mv "$tmp" "$RVPN_CIDR"
	chmod 644 "$RVPN_CIDR" 2>/dev/null || true
	log "cidr-sync: updated $RVPN_CIDR ($n prefixes)"
	cidr_sync_apply
	return 0
}
