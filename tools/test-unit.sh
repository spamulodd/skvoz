#!/bin/sh
# Lightweight unit checks (no OpenWrt required).
# Usage: sh tools/test-unit.sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
fail=0

ok() { printf 'OK  %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }

# --- CIDR filter (same regex as nft.sh) ---
cidr_filter() {
	awk '
		/^[[:space:]]*#/ { next }
		/^[[:space:]]*$/ { next }
		{
			gsub(/[[:space:]]/, "")
			if ($0 ~ /^[0-9]{1,3}(\.[0-9]{1,3}){3}\/[0-9]{1,2}$/) print $0
		}
	'
}

got=$(printf '%s\n' '91.105.192.0/23' 'not-a-cidr' '1.2.3.4/33x' '149.154.160.0/20' | cidr_filter | tr '\n' ' ')
case "$got" in
*'91.105.192.0/23'*'149.154.160.0/20'*) ok "cidr filter" ;;
*) bad "cidr filter got='$got'" ;;
esac

# --- domain filter ---
dom_filter() {
	awk '
		/^[[:space:]]*#/ { next }
		{
			gsub(/[[:space:]]/, "")
			if ($0 ~ /^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$/) print $0
		}
	'
}
got=$(printf '%s\n' 'telegram.org' 'evil";drop' 't.me' | dom_filter | tr '\n' ' ')
case "$got" in
*'telegram.org'*'t.me'*) ok "domain filter" ;;
*) bad "domain filter got='$got'" ;;
esac
case "$got" in
*evil*) bad "domain filter leaked evil" ;;
esac

# --- json_escape from common.sh (extract function) ---
json_escape() {
	printf '%s' "$1" | awk '
		BEGIN { ORS="" }
		{
			gsub(/\\/, "\\\\")
			gsub(/"/, "\\\"")
			gsub(/\t/, "\\t")
			gsub(/\r/, "\\r")
			gsub(/\n/, "\\n")
			print
		}'
}
je=$(json_escape 'a"b\c')
[ "$je" = 'a\"b\\c' ] && ok "json_escape" || bad "json_escape='$je'"

# --- vpn-cidr.txt all lines valid ---
bad_lines=0
while IFS= read -r line || [ -n "$line" ]; do
	case "$line" in
	''|\#*) continue ;;
	esac
	line=$(echo "$line" | tr -d '[:space:]')
	echo "$line" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' || bad_lines=$((bad_lines + 1))
done <"$ROOT/openwrt/usr/share/rvpn/rules/vpn-cidr.txt"
[ "$bad_lines" -eq 0 ] && ok "vpn-cidr.txt valid" || bad "vpn-cidr.txt invalid lines=$bad_lines"

# --- official TG range present ---
grep -q '91.105.192.0/23' "$ROOT/openwrt/usr/share/rvpn/rules/vpn-cidr.txt" \
	&& ok "telegram 91.105.192.0/23 present" \
	|| bad "missing 91.105.192.0/23"

# --- config insecure default ---
grep -q "option insecure '0'" "$ROOT/openwrt/etc/config/rvpn" \
	&& ok "hy2 insecure default 0" \
	|| bad "hy2 insecure default"

# --- dns.sh must not re-fakeip blindly ---
grep -q 'dns_vpn_ready' "$ROOT/openwrt/usr/lib/rvpn/dns.sh" \
	&& ok "dns_vpn_ready gate" \
	|| bad "dns_vpn_ready missing"
grep -q 'dns_apply_aaaa_only' "$ROOT/openwrt/usr/lib/rvpn/watchdog.sh" \
	&& ok "watchdog aaaa-only fail-open" \
	|| bad "watchdog still broken"

# --- UI no query token ---
grep -q "X-Skvoz-Token" "$ROOT/openwrt/www/rvpn/index.html" \
	&& ok "UI header token" || bad "UI header token"
grep -n "token=' +" "$ROOT/openwrt/www/rvpn/index.html" >/dev/null 2>&1 \
	&& bad "UI still appends token= to query" \
	|| ok "UI no token in query"

# --- postinst LAN bind ---
grep -q "rfc1918_filter='1'" "$ROOT/tools/postinst.sh" \
	&& ok "postinst rfc1918_filter=1" || bad "postinst rfc1918"
grep -q "zapret_enabled='0'" "$ROOT/tools/postinst.sh" \
	&& bad "postinst still forces layers off" \
	|| ok "postinst preserves layers on upgrade"

if [ "$fail" -ne 0 ]; then
	printf '\n%d test(s) failed\n' "$fail"
	exit 1
fi
printf '\nall tests passed\n'
