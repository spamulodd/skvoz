#!/bin/sh
# Skvoz installer for OpenWrt (apk or opkg).
# One-command (on router as root):
#   curl -fsSL https://raw.githubusercontent.com/spamulodd/skvoz/main/tools/install.sh | sh
#
# Env:
#   SKVOZ_EDITION=standard|slim|tiny|full   (default: standard)
#   SKVOZ_TARBALL=/path/to/skvoz-*-*.tar.gz
#   SKVOZ_URL=https://.../skvoz-*-standard.tar.gz
#   SKVOZ_REPO=spamulodd/skvoz
#   SKVOZ_VERSION=0.2.0   # optional pin
#
# Editions (flash): tiny < slim < standard < full — see tools/release-editions.md

set -eu

# When piped via curl|sh, $0 may be "sh" — treat as no local tree.
SCRIPT_PATH=$0
case "$SCRIPT_PATH" in
/*) ;;
*) SCRIPT_PATH=$(command -v "$0" 2>/dev/null || echo "$0") ;;
esac
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$SCRIPT_PATH")" 2>/dev/null && pwd) || SCRIPT_DIR=
ROOT_DIR=
OPENWRT_DIR=
POSTINST=
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/install.sh" ] || [ -f "$SCRIPT_DIR/postinst.sh" ]; then
	ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd) || ROOT_DIR=
	OPENWRT_DIR="${ROOT_DIR}/openwrt"
	POSTINST="$SCRIPT_DIR/postinst.sh"
	# shellcheck disable=SC1091
	[ -f "$SCRIPT_DIR/install-defaults.sh" ] && . "$SCRIPT_DIR/install-defaults.sh"
fi

log() { printf 'skvoz: %s\n' "$*"; }
warn() { printf 'skvoz: WARN: %s\n' "$*" >&2; }
die() { printf 'skvoz: ERROR: %s\n' "$*" >&2; exit 1; }

SKVOZ_REPO=${SKVOZ_REPO:-spamulodd/skvoz}
# standard = default; tiny/slim = tight flash; full = docs+all
SKVOZ_EDITION=${SKVOZ_EDITION:-standard}
case "$SKVOZ_EDITION" in
tiny|slim|standard|full|all) ;;
*)
	warn "unknown SKVOZ_EDITION=$SKVOZ_EDITION — using standard"
	SKVOZ_EDITION=standard
	;;
esac
[ "$SKVOZ_EDITION" = "all" ] && SKVOZ_EDITION=full

skvoz_mirror_urls() {
	orig=$1
	echo "$orig"
	echo "https://ghproxy.com/${orig}"
	echo "https://mirror.ghproxy.com/${orig}"
}

fetch_to() {
	url=$1
	out=$2
	for u in $(skvoz_mirror_urls "$url"); do
		if command -v curl >/dev/null 2>&1; then
			curl -fsSL --connect-timeout 8 --max-time 180 -L "$u" -o "$out" 2>/dev/null && [ -s "$out" ] && return 0
		elif command -v wget >/dev/null 2>&1; then
			wget -qO "$out" "$u" 2>/dev/null && [ -s "$out" ] && return 0
		fi
	done
	return 1
}

detect_pkg_mgr() {
	if command -v apk >/dev/null 2>&1; then
		echo apk
	elif command -v opkg >/dev/null 2>&1; then
		echo opkg
	else
		die "neither apk nor opkg — is this OpenWrt?"
	fi
}

PKG_MGR=$(detect_pkg_mgr)
log "package manager: $PKG_MGR"

try_install() {
	pkg=$1
	case "$PKG_MGR" in
	apk) apk add --no-cache "$pkg" >/dev/null 2>&1 && return 0 ;;
	opkg) opkg install "$pkg" >/dev/null 2>&1 && return 0 ;;
	esac
	return 1
}

try_install_any() {
	for pkg in "$@"; do
		if try_install "$pkg"; then
			log "installed: $pkg"
			return 0
		fi
	done
	warn "could not install any of: $*"
	return 1
}

install_dependencies() {
	log "installing dependencies..."
	try_install sing-box || warn "sing-box not installed — install manually for VPN"
	try_install_any libnetfilter-queue libnetfilter-queue1 libnetfilter-queue1.0.5 || true
	try_install_any libnfnetlink libnfnetlink0 || true
	try_install kmod-nfnetlink-queue || true
	try_install kmod-nft-queue || true
	try_install kmod-nft-tproxy || true
	try_install kmod-nft-socket || true
	try_install curl || true
	try_install ca-bundle || try_install ca-certificates || true
}

install_openwrt_tree() {
	src=$1
	[ -d "$src" ] || die "source tree missing: $src"
	log "installing files from $src ..."
	find "$src" -type f | while IFS= read -r f; do
		rel=${f#"$src"/}
		dest="/$rel"
		mkdir -p "$(dirname "$dest")"
		case "$rel" in
		etc/init.d/*|usr/bin/*|usr/lib/rvpn/*.sh|www/rvpn/cgi-bin/*)
			install -m 755 "$f" "$dest"
			;;
		*)
			install -m 644 "$f" "$dest"
			;;
		esac
	done
}

extract_tarball_to_root() {
	tarball=$1
	log "extracting $tarball to / ..."
	tar xzf "$tarball" -C /
}

# Resolve latest release asset for edition (fallback: full → all → any skvoz-*.tar.gz)
resolve_release_url() {
	ed=${1:-$SKVOZ_EDITION}
	api="https://api.github.com/repos/${SKVOZ_REPO}/releases/latest"
	json=
	tmpj=$(mktemp)
	if fetch_to "$api" "$tmpj"; then
		json=$(cat "$tmpj")
	fi
	rm -f "$tmpj"
	[ -n "$json" ] || return 1
	url=
	for try in "$ed" full all standard slim tiny; do
		url=$(printf '%s' "$json" | grep -oE "https://[^\"]+skvoz-[^\"]+-${try}\\.tar\\.gz" | head -1)
		[ -n "$url" ] && break
	done
	[ -n "$url" ] || url=$(printf '%s' "$json" | grep -oE 'https://[^"]+skvoz-[^"]+\.tar\.gz' | head -1)
	[ -n "$url" ] || return 1
	echo "$url"
}

obtain_files() {
	if [ -n "${OPENWRT_DIR:-}" ] && [ -d "$OPENWRT_DIR/etc" ] && [ -d "$OPENWRT_DIR/usr" ]; then
		install_openwrt_tree "$OPENWRT_DIR"
		return 0
	fi

	if [ -n "${SKVOZ_TARBALL:-}" ] && [ -f "$SKVOZ_TARBALL" ]; then
		extract_tarball_to_root "$SKVOZ_TARBALL"
		return 0
	fi

	url=${SKVOZ_URL:-}
	if [ -z "$url" ]; then
		log "resolving latest release ($SKVOZ_REPO edition=$SKVOZ_EDITION)..."
		url=$(resolve_release_url "$SKVOZ_EDITION") || url=
	fi
	if [ -z "$url" ] && [ -n "${SKVOZ_VERSION:-}" ]; then
		ver=${SKVOZ_VERSION#v}
		url="https://github.com/${SKVOZ_REPO}/releases/download/v${ver}/skvoz-${ver}-${SKVOZ_EDITION}.tar.gz"
	fi
	[ -n "$url" ] || die "no file source: GitHub unreachable. Set SKVOZ_URL=... or SKVOZ_EDITION=tiny|slim|standard|full"

	log "downloading $url"
	tmp=$(mktemp)
	fetch_to "$url" "$tmp" || {
		rm -f "$tmp"
		die "download failed (GitHub blocked?). Use SKVOZ_URL=... from a reachable host"
	}
	extract_tarball_to_root "$tmp"
	rm -f "$tmp"
}

print_credentials() {
	lan=$(uci -q get network.lan.ipaddr 2>/dev/null || true)
	lan=${lan%%/*}
	case "$lan" in *[!0-9.]*|'') lan=192.168.1.1 ;; esac
	secret=$(uci -q get rvpn.main.ui_secret 2>/dev/null || true)
	if [ -z "$secret" ] && [ -f /usr/lib/rvpn/common.sh ]; then
		# shellcheck disable=SC1091
		. /usr/lib/rvpn/common.sh
		secret=$(ensure_ui_secret 2>/dev/null || true)
	fi
	ed=$(cat /usr/share/rvpn/EDITION 2>/dev/null || echo "$SKVOZ_EDITION")
	ver=$(cat /usr/share/rvpn/VERSION 2>/dev/null || echo "?")
	echo ""
	echo "========================================"
	echo "  Skvoz ${ver} (${ed}) installed"
	echo "  UI:       http://${lan}:81/"
	echo "  Password: ${secret:-<run: uci get rvpn.main.ui_secret>}"
	echo "  Next:     open the link and finish the setup wizard"
	echo "========================================"
	echo ""
}

run_postinst() {
	if [ -n "${POSTINST:-}" ] && [ -f "$POSTINST" ]; then
		# shellcheck disable=SC1090
		. "$POSTINST"
		skvoz_postinst
		return 0
	fi
	# curl|sh — use installed postinst on router if present
	if [ -f /usr/lib/rvpn/../share/rvpn/../.. ]; then
		:
	fi
	if [ -f /usr/share/rvpn/../../tools/postinst.sh ]; then
		:
	fi
	# Prefer packaged postinst copied into /usr/lib/rvpn/postinst.sh if we ship it later;
	# otherwise inline minimal + call installed helpers.
	chmod +x /etc/init.d/rvpn /usr/bin/rvpnctl /www/rvpn/cgi-bin/rvpn.cgi 2>/dev/null || true
	chmod +x /usr/lib/rvpn/*.sh 2>/dev/null || true
	mkdir -p /opt/rvpn /tmp/rvpn
	chmod 700 /tmp/rvpn 2>/dev/null || true
	lan=$(uci -q get network.lan.ipaddr 2>/dev/null)
	lan=${lan%%/*}
	case "$lan" in *[!0-9.]*|'') lan=192.168.1.1 ;; esac
	uci -q delete uhttpd.rvpn
	uci set uhttpd.rvpn=uhttpd
	uci set uhttpd.rvpn.listen_http="$lan:81"
	uci set uhttpd.rvpn.home='/www/rvpn'
	uci set uhttpd.rvpn.cgi_prefix='/cgi-bin'
	uci set uhttpd.rvpn.script_timeout='180'
	uci set uhttpd.rvpn.network_timeout='60'
	uci set uhttpd.rvpn.tcp_keepalive='1'
	uci set uhttpd.rvpn.rfc1918_filter='1'
	uci set uhttpd.rvpn.max_requests='40'
	uci commit uhttpd
	if [ -f /usr/lib/rvpn/common.sh ]; then
		# shellcheck disable=SC1091
		. /usr/lib/rvpn/common.sh
		ensure_ui_secret >/dev/null 2>&1 || true
		ensure_clash_secret >/dev/null 2>&1 || true
	fi
	uci -q set rvpn.main.setup_done='0'
	uci commit rvpn
	/etc/init.d/uhttpd restart 2>/dev/null || true
	/etc/init.d/rvpn enable 2>/dev/null || true
	/etc/init.d/rvpn stop 2>/dev/null || true
	if [ -f /usr/lib/rvpn/zapret-sync.sh ]; then
		# shellcheck disable=SC1091
		. /usr/lib/rvpn/zapret-sync.sh
		zapret_bootstrap_first_install || warn "Flowseal/GitHub blocked — sync after VPN"
	fi
	if [ -f /usr/lib/rvpn/nfqws-fetch.sh ]; then
		# shellcheck disable=SC1091
		. /usr/lib/rvpn/nfqws-fetch.sh
		nfqws_fetch_run || warn "nfqws download deferred — after VPN: rvpnctl nfqws-fetch"
	fi
}

main() {
	[ "$(id -u)" -eq 0 ] || die "run as root on the router"

	install_dependencies
	obtain_files
	run_postinst
	print_credentials
	log "layers default OFF until wizard / rvpnctl enable-*"
}

main "$@"
