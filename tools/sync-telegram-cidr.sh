#!/bin/sh
# Refresh Telegram IPv4 block inside vpn-cidr.txt from official source.
# Usage: sh tools/sync-telegram-cidr.sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
OUT="$ROOT/openwrt/usr/share/rvpn/rules/vpn-cidr.txt"
URL="${TELEGRAM_CIDR_URL:-https://core.telegram.org/resources/cidr.txt}"
TMP=$(mktemp)

cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

if command -v curl >/dev/null 2>&1; then
	curl -fsSL "$URL" -o "$TMP"
elif command -v wget >/dev/null 2>&1; then
	wget -qO "$TMP" "$URL"
else
	echo "need curl or wget" >&2
	exit 1
fi

TG=$(awk '
	/^[[:space:]]*#/ { next }
	/^[[:space:]]*$/ { next }
	/:/{ next }  # skip IPv6
	{
		gsub(/[[:space:]]/, "")
		if ($0 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/) print $0
	}
' "$TMP" | sort -u)

[ -n "$TG" ] || { echo "empty Telegram IPv4 list from $URL" >&2; exit 1; }

META=$(awk '
	BEGIN { keep=0 }
	/^# --- Meta/ { keep=1 }
	keep && /^[0-9]/ { print }
' "$OUT" 2>/dev/null || true)

{
	echo "# VPN by IP (app connects to DC/CDN by address, not only DNS)."
	echo "# Telegram IPv4 — official $URL"
	echo "# Generated: $(date -u +%Y-%m-%dT%H:%MZ) via tools/sync-telegram-cidr.sh"
	echo "#"
	echo "# --- Telegram (official) ---"
	echo "$TG"
	echo "# --- Telegram (BGP extras, media/CDN) ---"
	echo "95.161.64.0/20"
	echo "# --- Meta / Facebook / Instagram / WhatsApp (AS32934) ---"
	if [ -n "$META" ]; then
		echo "$META"
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
} >"$OUT"

echo "updated $OUT"
echo "$TG" | sed 's/^/  /'
