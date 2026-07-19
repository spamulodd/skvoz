#!/bin/sh
# Refresh vpn-cidr.txt: Telegram official + ASN prefixes for Meta/X/Discord/Telegram BGP.
# Usage: sh tools/sync-vpn-cidr.sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
OUT="$ROOT/openwrt/usr/share/rvpn/rules/vpn-cidr.txt"
ASN_IP_BASE="${ASN_IP_BASE:-https://raw.githubusercontent.com/ipverse/asn-ip/master/as}"
TELEGRAM_CIDR_URL="${TELEGRAM_CIDR_URL:-https://core.telegram.org/resources/cidr.txt}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT HUP TERM

fetch() {
	url=$1
	dest=$2
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --connect-timeout 15 --max-time 60 "$url" -o "$dest"
	elif command -v wget >/dev/null 2>&1; then
		wget -qO "$dest" "$url"
	else
		echo "need curl or wget" >&2
		exit 1
	fi
}

filter_v4() {
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

fetch_asn() {
	asn=$1
	label=$2
	out=$WORK/as$asn.txt
	url="$ASN_IP_BASE/$asn/ipv4-aggregated.txt"
	if fetch "$url" "$out" 2>/dev/null; then
		filter_v4 <"$out" >"$WORK/as$asn.v4"
		n=$(wc -l <"$WORK/as$asn.v4" | tr -d ' ')
		echo "  AS$asn ($label): $n prefixes" >&2
		[ "$n" -gt 0 ]
		return $?
	fi
	echo "  WARN: AS$asn ($label) fetch failed" >&2
	return 1
}

echo "Fetching Telegram official CIDR..." >&2
fetch "$TELEGRAM_CIDR_URL" "$WORK/tg-official.txt"
filter_v4 <"$WORK/tg-official.txt" >"$WORK/tg.v4"
[ -s "$WORK/tg.v4" ] || { echo "empty Telegram IPv4 list" >&2; exit 1; }
echo "  telegram.org: $(wc -l <"$WORK/tg.v4" | tr -d ' ') prefixes" >&2

echo "Fetching ASN aggregates (ipverse)..." >&2
: >"$WORK/tg-asn.v4"
for asn in 62041 62014 59930 44907 211157; do
	if fetch_asn "$asn" "Telegram"; then
		cat "$WORK/as$asn.v4" >>"$WORK/tg-asn.v4"
	fi
done
{
	cat "$WORK/tg-asn.v4"
	echo "95.161.64.0/20"
} | filter_v4 >"$WORK/tg-extra.v4"

fetch_asn 32934 "Meta/Facebook" || true
fetch_asn 13414 "Twitter/X" || true
fetch_asn 49544 "Discord voice (i3D)" || true

ts=$(date -u +%Y-%m-%dT%H:%MZ)

{
	echo "# VPN by IP (app connects to DC/CDN by address, not only DNS)."
	echo "# Auto-generated: $ts via tools/sync-vpn-cidr.sh"
	echo "# Sources: $TELEGRAM_CIDR_URL + $ASN_IP_BASE/{ASN}/ipv4-aggregated.txt"
	echo "# Re-run: sh tools/sync-vpn-cidr.sh   (router: rvpnctl sync-cidr)"
	echo "#"
	echo "# --- Telegram (official) ---"
	cat "$WORK/tg.v4"
	echo "# --- Telegram (ASN / BGP extras) ---"
	cat "$WORK/tg-extra.v4"
	echo "# --- Meta / Facebook / Instagram / WhatsApp (AS32934) ---"
	if [ -f "$WORK/as32934.v4" ]; then
		cat "$WORK/as32934.v4"
	else
		cat <<'EOF'
31.13.24.0/21
31.13.64.0/18
66.220.144.0/20
69.63.176.0/20
69.171.224.0/19
74.119.76.0/22
102.132.96.0/20
129.134.0.0/17
157.240.0.0/17
173.252.64.0/18
179.60.192.0/22
185.60.216.0/22
204.15.20.0/22
EOF
	fi
	echo "# --- Twitter / X (AS13414) ---"
	[ -f "$WORK/as13414.v4" ] && cat "$WORK/as13414.v4"
	echo "# --- Discord voice / RTC (AS49544 i3D; CF edge stays on domains) ---"
	[ -f "$WORK/as49544.v4" ] && cat "$WORK/as49544.v4"
} >"$OUT"

count=$(grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$OUT" | wc -l | tr -d ' ')
echo "updated $OUT ($count IPv4 prefixes)"
