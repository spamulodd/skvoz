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

# --- UI auth: cookie + header, no query token ---
grep -q "X-Skvoz-Token" "$ROOT/openwrt/www/rvpn/index.html" \
	&& ok "UI header token" || bad "UI header token"
grep -q "credentials: 'same-origin'" "$ROOT/openwrt/www/rvpn/index.html" \
	&& ok "UI same-origin cookies" || bad "UI same-origin cookies"
if grep -E "url \+= '&token='" "$ROOT/openwrt/www/rvpn/index.html" >/dev/null 2>&1; then
	bad "UI still appends token= to query"
else
	ok "UI no token in query"
fi

# --- postinst LAN bind ---
grep -q "rfc1918_filter='1'" "$ROOT/tools/postinst.sh" \
	&& ok "postinst rfc1918_filter=1" || bad "postinst rfc1918"
grep -q "zapret_enabled='0'" "$ROOT/tools/postinst.sh" \
	&& bad "postinst still forces layers off" \
	|| ok "postinst preserves layers on upgrade"

# --- update.sh: semver compare (source helpers without OpenWrt paths) ---
update_version_cmp() {
	a=$(printf '%s' "$1" | sed 's/^v//;s/\r//g;s/[^0-9A-Za-z.].*//')
	b=$(printf '%s' "$2" | sed 's/^v//;s/\r//g;s/[^0-9A-Za-z.].*//')
	[ -n "$a" ] || a=0
	[ -n "$b" ] || b=0
	if [ "$a" = "$b" ]; then echo 0; return 0; fi
	case "$a$b" in
	*[!0-9.]*) [ "$a" \> "$b" ] && echo 1 || echo -1; return 0 ;;
	esac
	IFS=.
	# shellcheck disable=SC2086
	set -- $a
	a1=${1:-0} a2=${2:-0} a3=${3:-0} a4=${4:-0}
	# shellcheck disable=SC2086
	set -- $b
	b1=${1:-0} b2=${2:-0} b3=${3:-0} b4=${4:-0}
	IFS=' '
	for pair in "$a1:$b1" "$a2:$b2" "$a3:$b3" "$a4:$b4"; do
		x=${pair%%:*}; y=${pair#*:}
		case "$x" in ''|*[!0-9]*) x=0 ;; esac
		case "$y" in ''|*[!0-9]*) y=0 ;; esac
		if [ "$x" -gt "$y" ]; then echo 1; return 0; fi
		if [ "$x" -lt "$y" ]; then echo -1; return 0; fi
	done
	echo 0
}
[ "$(update_version_cmp 0.2.2 0.2.1)" = "1" ] && ok "semver 0.2.2>0.2.1" || bad "semver gt"
[ "$(update_version_cmp 0.2.1 0.2.10)" = "-1" ] && ok "semver 0.2.1<0.2.10" || bad "semver lt"
[ "$(update_version_cmp 0.2.1 0.2.1)" = "0" ] && ok "semver eq" || bad "semver eq"
[ "$(update_version_cmp v1.0.0 0.9.9)" = "1" ] && ok "semver strip v" || bad "semver strip v"

# --- update.sh integrity / path guards present ---
grep -q 'update_tar_members_safe' "$ROOT/openwrt/usr/lib/rvpn/update.sh" \
	&& ok "tar member safety" || bad "tar member safety"
grep -q 'checksum mismatch' "$ROOT/openwrt/usr/lib/rvpn/update.sh" \
	&& ok "checksum verify" || bad "checksum verify"
grep -q 'adblock-allow.txt' "$ROOT/openwrt/usr/lib/rvpn/update.sh" \
	&& ok "preserve adblock-allow" || bad "preserve adblock-allow"
grep -q 'update_nfqws_needed' "$ROOT/openwrt/usr/lib/rvpn/update.sh" \
	&& ok "conditional nfqws fetch" || bad "conditional nfqws fetch"
grep -q 'update-status' "$ROOT/openwrt/www/rvpn/cgi-bin/rvpn.cgi" \
	&& ok "CGI update-status" || bad "CGI update-status"
grep -q 'shipped_readonly' "$ROOT/openwrt/usr/lib/rvpn/ui-api.sh" \
	&& ok "shipped lists readonly" || bad "shipped lists readonly"
grep -q 'password_set' "$ROOT/openwrt/usr/lib/rvpn/ui-api.sh" \
	&& ok "vps password masked" || bad "vps password masked"
grep -q 'cgi_read_body' "$ROOT/openwrt/www/rvpn/cgi-bin/rvpn.cgi" \
	&& ok "POST body reader" || bad "POST body reader"
grep -q "method: 'POST'" "$ROOT/openwrt/www/rvpn/index.html" \
	&& ok "UI domains-set POST" || bad "UI domains-set POST"
grep -q 'SHA256SUMS' "$ROOT/tools/build-release.sh" \
	&& ok "build emits SHA256SUMS" || bad "build emits SHA256SUMS"

# --- CRLF strip after OTA ---
grep -q "s/\\\\r\\$//" "$ROOT/openwrt/usr/lib/rvpn/update.sh" \
	&& ok "OTA CRLF strip" || bad "OTA CRLF strip"

# --- nfqws arch prefers DISTRIB_ARCH ---
grep -q 'DISTRIB_ARCH' "$ROOT/openwrt/usr/lib/rvpn/nfqws-fetch.sh" \
	&& ok "nfqws DISTRIB_ARCH" || bad "nfqws DISTRIB_ARCH"

# --- copy_safe path traversal reject (inline mirror) ---
reject_rel() {
	rel_path=$1
	case "$rel_path" in
	''|/*) return 0 ;;
	esac
	printf '%s\n' "$rel_path" | tr '/' '\n' | grep -qx '\.\.' && return 0
	return 1
}
reject_rel '../etc/passwd' && ok "reject .. path" || bad "reject .. path"
reject_rel 'usr/lib/rvpn/x.sh' && bad "false reject good path" || ok "allow good path"

grep -q 'patreon.com' "$ROOT/openwrt/usr/share/rvpn/rules/patreon-domains.txt" \
	&& ok "patreon domains file" || bad "patreon-domains missing"
grep -E '^[[:space:]]*patreon\.com[[:space:]]*$' "$ROOT/openwrt/usr/share/rvpn/rules/vpn-domains.txt" \
	&& bad "patreon still in vpn-domains (urltest)" || ok "patreon not in vpn-domains urltest"
grep -q 'sb_register_tag' "$ROOT/openwrt/usr/lib/rvpn/singbox.sh" \
	&& ok "patreon dedicated outbound" || bad "patreon route missing"
grep -q 'patreon_dom.*"server": "fakeip"' "$ROOT/openwrt/usr/lib/rvpn/singbox.sh" \
	&& ok "patreon FakeIP dns" || bad "patreon not FakeIP"
# Early ip_cidr must not bundle FakeIP with vpn_cidr (breaks Patreon domain route)
grep -q 'ip_route_json=\[\\"\$fake' "$ROOT/openwrt/usr/lib/rvpn/singbox.sh" \
	&& bad "FakeIP still in early ip_cidr" || ok "FakeIP after sniff"

# --- Telegram: VPN lists, not games/dpi; time100 stays off VPN ---
grep -q 'cdn-telegram.org' "$ROOT/openwrt/usr/share/rvpn/rules/vpn-domains.txt" \
	&& ok "telegram CDN in vpn-domains" || bad "telegram CDN missing"
grep -q 'tg.dev' "$ROOT/openwrt/usr/share/rvpn/rules/vpn-domains.txt" \
	&& ok "tg.dev in vpn-domains" || bad "tg.dev missing"
grep -qi 'telegram' "$ROOT/openwrt/usr/share/rvpn/rules/games-domains.txt" \
	&& bad "telegram in games-domains" || ok "telegram not in games-domains"
grep -qi 'telegram\|^t\.me$' "$ROOT/openwrt/usr/share/rvpn/rules/dpi.txt" \
	&& bad "telegram in dpi.txt" || ok "telegram not in dpi.txt"
grep -E '^[[:space:]]*time100\.ru[[:space:]]*$' "$ROOT/openwrt/usr/share/rvpn/rules/vpn-domains.txt" \
	&& bad "time100.ru in vpn-domains" || ok "time100.ru not on VPN"
grep -q 'time100.ru' "$ROOT/openwrt/usr/share/rvpn/rules/dpi.txt" \
	&& ok "time100.ru in dpi.txt" || bad "time100.ru missing from dpi"

# --- App Store must stay DIRECT (FakeIP itunes/mzstatic hangs iOS App Store) ---
grep -E '^[[:space:]]*(itunes\.apple\.com|mzstatic\.com|music\.apple\.com)[[:space:]]*$' \
	"$ROOT/openwrt/usr/share/rvpn/rules/vpn-domains.txt" \
	&& bad "App Store domain on VPN" || ok "App Store domains not on VPN"
grep -q 'push.apple.com' "$ROOT/openwrt/usr/share/rvpn/rules/vpn-domains.txt" \
	&& ok "APNs push on VPN" || bad "push.apple.com missing"

# --- sing-box: dns-in first; vpn_cidr early; FakeIP after sniff (Patreon domain route) ---
grep -q '"inbound": \["dns-in"\]' "$ROOT/openwrt/usr/lib/rvpn/singbox.sh" \
	&& ok "dns-in hijack first" || bad "dns-in hijack missing"
grep -q 'early_ip_rule=' "$ROOT/openwrt/usr/lib/rvpn/singbox.sh" \
	&& ok "singbox early vpn_cidr route" || bad "singbox early ip route"
grep -q 'fake_catch_json' "$ROOT/openwrt/usr/lib/rvpn/singbox.sh" \
	&& ok "singbox FakeIP catch after sniff" || bad "FakeIP catch missing"
grep -q '"timeout": "200ms"' "$ROOT/openwrt/usr/lib/rvpn/singbox.sh" \
	&& ok "singbox sniff 200ms" || bad "singbox sniff timeout"
din=$(grep -n '"inbound": \["dns-in"\]' "$ROOT/openwrt/usr/lib/rvpn/singbox.sh" | head -1 | cut -d: -f1)
sniff=$(grep -n '"action": "sniff"' "$ROOT/openwrt/usr/lib/rvpn/singbox.sh" | head -1 | cut -d: -f1)
pat=$(grep -n 'patreon_dom.*"outbound"' "$ROOT/openwrt/usr/lib/rvpn/singbox.sh" | head -1 | cut -d: -f1)
fake=$(grep -n 'fake_catch_json' "$ROOT/openwrt/usr/lib/rvpn/singbox.sh" | tail -1 | cut -d: -f1)
priv=$(grep -n 'ip_is_private' "$ROOT/openwrt/usr/lib/rvpn/singbox.sh" | head -1 | cut -d: -f1)
[ -n "$din" ] && [ -n "$sniff" ] && [ "$din" -lt "$sniff" ] \
	&& ok "dns-in before sniff" || bad "dns-in order"
[ -n "$sniff" ] && [ -n "$pat" ] && [ "$sniff" -lt "$pat" ] \
	&& ok "sniff before patreon route" || bad "patreon before sniff"
[ -n "$pat" ] && [ -n "$fake" ] && [ "$pat" -lt "$fake" ] \
	&& ok "patreon before FakeIP catchall" || bad "FakeIP catch before patreon"
[ -n "$fake" ] && [ -n "$priv" ] && [ "$fake" -lt "$priv" ] \
	&& ok "FakeIP before ip_is_private" || bad "private before FakeIP"
grep -q 'up_mbps' "$ROOT/openwrt/usr/lib/rvpn/singbox.sh" \
	&& ok "HY2 bandwidth hints" || bad "HY2 bandwidth hints"
grep -q "hy2_up_mbps '0'" "$ROOT/openwrt/etc/config/rvpn" \
	&& ok "HY2 bw default omit" || bad "HY2 bw default"
grep -q "urltest_interval '2m'" "$ROOT/openwrt/etc/config/rvpn" \
	&& ok "urltest default 2m" || bad "urltest interval default"
grep -q 'update.restart' "$ROOT/openwrt/usr/lib/rvpn/update.sh" \
	&& ok "OTA flags restart" || bad "OTA no restart flag"

# --- nft QUIC skips vpn_cidr (TG real IPs) ---
grep -q 'ip daddr @vpn_cidr accept' "$ROOT/openwrt/usr/lib/rvpn/nft.sh" \
	&& ok "nft quic skip vpn_cidr" || bad "nft quic skip vpn_cidr"

# --- DNS orphan heal / failsafe ---
grep -q 'dns_heal_orphan' "$ROOT/openwrt/usr/lib/rvpn/dns.sh" \
	&& ok "dns_heal_orphan" || bad "dns_heal_orphan missing"
grep -q 'DNS_PERSIST_DIR' "$ROOT/openwrt/usr/lib/rvpn/dns.sh" \
	&& ok "dns persistent backup" || bad "dns persistent backup"
grep -q 'dns_heal_orphan' "$ROOT/openwrt/etc/init.d/rvpn" \
	&& ok "init heal on start" || bad "init heal on start"
grep -q 'both layers off' "$ROOT/openwrt/etc/init.d/rvpn" \
	&& ok "init both-off cleanup" || bad "init both-off cleanup"
grep -q "sysCmd('start')" "$ROOT/openwrt/www/rvpn/index.html" \
	&& ok "UI start button wired" || bad "UI start missing"
grep -q 'doFailsafe' "$ROOT/openwrt/www/rvpn/index.html" \
	&& ok "UI failsafe" || bad "UI failsafe"
grep -q 'ui_failsafe_run' "$ROOT/openwrt/usr/lib/rvpn/ui-api.sh" \
	&& ok "ui_failsafe_run" || bad "ui_failsafe_run"
grep -q 'failsafe)' "$ROOT/openwrt/www/rvpn/cgi-bin/rvpn.cgi" \
	&& ok "CGI failsafe" || bad "CGI failsafe"
grep -q 'dns_orphan' "$ROOT/openwrt/usr/lib/rvpn/selftest.sh" \
	&& ok "selftest dns_orphan" || bad "selftest dns_orphan"
grep -q 'failsafe_hint' "$ROOT/openwrt/usr/lib/rvpn/selftest.sh" \
	&& ok "selftest failsafe_hint" || bad "selftest failsafe_hint"
grep -q '\\037' "$ROOT/openwrt/usr/lib/rvpn/clash-parse.awk" \
	&& ok "sub US delimiter" || bad "sub US delimiter"
grep -q 'corrupt reality' "$ROOT/openwrt/usr/lib/rvpn/singbox.sh" \
	&& ok "skip corrupt reality nodes" || bad "skip corrupt reality"
grep -q "tr -d '\\\\r'" "$ROOT/openwrt/usr/lib/rvpn/zapret.sh" \
	&& ok "nfqws CRLF strip" || bad "nfqws CRLF strip"
grep -q 'dns_lan_resolve_ok' "$ROOT/openwrt/usr/lib/rvpn/dns.sh" \
	&& ok "dns_lan_resolve_ok" || bad "dns_lan_resolve_ok"
grep -q 'dns_lan_resolve_ok' "$ROOT/openwrt/etc/init.d/rvpn" \
	&& ok "init DNS probe" || bad "init DNS probe"
grep -q 'rvpn_failsafe_hold' "$ROOT/openwrt/usr/lib/rvpn/common.sh" \
	&& ok "failsafe hold helpers" || bad "failsafe hold helpers"
grep -q 'failsafe_hold' "$ROOT/openwrt/etc/init.d/rvpn" \
	&& ok "init respects hold" || bad "init respects hold"
grep -q 'RVPN_CLEAR_HOLD=1' "$ROOT/openwrt/www/rvpn/cgi-bin/rvpn.cgi" \
	&& ok "CGI start clears hold" || bad "CGI start clears hold"
grep -q 'rvpn_with_lock_timeout' "$ROOT/openwrt/www/rvpn/cgi-bin/rvpn.cgi" \
	&& ok "failsafe short lock" || bad "failsafe short lock"
grep -q '^failsafe)' "$ROOT/openwrt/usr/bin/rvpnctl" \
	&& ok "rvpnctl failsafe" || bad "rvpnctl failsafe"
grep -q 'corrupt_nodes' "$ROOT/openwrt/usr/lib/rvpn/health.sh" \
	&& ok "status corrupt_nodes" || bad "status corrupt_nodes"
grep -q 'zapret-strategies/\*.strategy' "$ROOT/openwrt/usr/lib/rvpn/update.sh" \
	&& ok "OTA strip strategy CRLF" || bad "OTA strip strategy CRLF"
grep -q 'symlink escape' "$ROOT/openwrt/usr/lib/rvpn/update.sh" \
	&& ok "OTA symlink reject" || bad "OTA symlink reject"
grep -q 'failsafe_hold' "$ROOT/openwrt/www/rvpn/index.html" \
	&& ok "UI hold banner" || bad "UI hold banner"

# --- dns backup sanity (no OpenWrt): empty/FakeIP files ---
tmpd=$(mktemp -d)
listen=127.0.0.42
printf '%s\n' '8.8.8.8' >"$tmpd/ok"
printf '%s\n' "$listen" >"$tmpd/bad"
: >"$tmpd/empty"
dns_backup_file_sane_test() {
	f=$1
	[ -f "$f" ] || return 1
	grep -Fq "$listen" "$f" 2>/dev/null && return 1
	return 0
}
dns_backup_file_sane_test "$tmpd/ok" && ok "backup sane ok" || bad "backup sane ok"
dns_backup_file_sane_test "$tmpd/bad" && bad "backup rejects fakeip" || ok "backup rejects fakeip"
dns_backup_file_sane_test "$tmpd/empty" && ok "empty backup sane" || bad "empty backup sane"
rm -rf "$tmpd"

if [ "$fail" -ne 0 ]; then
	printf '\n%d test(s) failed\n' "$fail"
	exit 1
fi
printf '\nall tests passed\n'
