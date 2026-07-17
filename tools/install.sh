#!/bin/sh
# Skvoz installer for OpenWrt (apk or opkg). No SDK required.
# Usage on router:
#   curl -fsSL .../install.sh | sh
#   sh install.sh
# Env:
#   SKVOZ_TARBALL=/path/to/skvoz-1.0.0-all.tar.gz
#   SKVOZ_URL=https://.../skvoz-1.0.0-all.tar.gz
#   SKVOZ_VERSION=1.0.0

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
OPENWRT_DIR="$ROOT_DIR/openwrt"
POSTINST="$SCRIPT_DIR/postinst.sh"

log() { printf 'skvoz: %s\n' "$*"; }
warn() { printf 'skvoz: WARN: %s\n' "$*" >&2; }
die() { printf 'skvoz: ERROR: %s\n' "$*" >&2; exit 1; }

default_version() {
	if [ -f "$ROOT_DIR/package/skvoz/Makefile" ]; then
		sed -n 's/^PKG_VERSION:=//p' "$ROOT_DIR/package/skvoz/Makefile" | head -1
	else
		echo "1.0.0"
	fi
}

SKVOZ_VERSION=${SKVOZ_VERSION:-$(default_version)}
SKVOZ_VERSION=${SKVOZ_VERSION#v}

detect_pkg_mgr() {
	if command -v apk >/dev/null 2>&1; then
		echo apk
	elif command -v opkg >/dev/null 2>&1; then
		echo opkg
	else
		die "neither apk nor opkg found — is this OpenWrt?"
	fi
}

PKG_MGR=$(detect_pkg_mgr)
log "package manager: $PKG_MGR"

try_install() {
	pkg=$1
	case "$PKG_MGR" in
	apk)
		apk add --no-cache "$pkg" >/dev/null 2>&1 && return 0
		;;
	opkg)
		opkg install "$pkg" >/dev/null 2>&1 && return 0
		;;
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

	# sing-box is optional (may need extra feed)
	try_install sing-box || warn "sing-box not installed — install manually for VPN layer"

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

fetch_tarball() {
	url=$1
	tmp=$(mktemp)
	trap 'rm -f "$tmp"' EXIT INT HUP TERM
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL "$url" -o "$tmp"
	elif command -v wget >/dev/null 2>&1; then
		wget -qO "$tmp" "$url"
	else
		die "curl or wget required to download release"
	fi
	echo "$tmp"
}

extract_tarball_to_root() {
	tarball=$1
	log "extracting $tarball to / ..."
	tar xzf "$tarball" -C /
}

obtain_files() {
	if [ -d "$OPENWRT_DIR/etc" ] && [ -d "$OPENWRT_DIR/usr" ]; then
		install_openwrt_tree "$OPENWRT_DIR"
		return
	fi

	if [ -n "${SKVOZ_TARBALL:-}" ] && [ -f "$SKVOZ_TARBALL" ]; then
		extract_tarball_to_root "$SKVOZ_TARBALL"
		return
	fi

	if [ -n "${SKVOZ_URL:-}" ]; then
		tmp=$(fetch_tarball "$SKVOZ_URL")
		extract_tarball_to_root "$tmp"
		return
	fi

	die "no file source: clone repo (openwrt/), set SKVOZ_TARBALL, or SKVOZ_URL"
}

run_postinst() {
	if [ -f "$POSTINST" ]; then
		# shellcheck disable=SC1090
		. "$POSTINST"
	else
		# curl | sh — postinst.sh not present; inline minimal config
		skvoz_postinst() {
			chmod +x /etc/init.d/rvpn /usr/bin/rvpnctl /www/rvpn/cgi-bin/rvpn.cgi 2>/dev/null || true
			chmod +x /usr/lib/rvpn/*.sh 2>/dev/null || true
			mkdir -p /opt/rvpn /tmp/rvpn
			uci -q delete uhttpd.rvpn
			uci set uhttpd.rvpn=uhttpd
			uci set uhttpd.rvpn.listen_http='0.0.0.0:81'
			uci set uhttpd.rvpn.home='/www/rvpn'
			uci set uhttpd.rvpn.cgi_prefix='/cgi-bin'
			uci set uhttpd.rvpn.script_timeout='120'
			uci set uhttpd.rvpn.network_timeout='60'
			uci set uhttpd.rvpn.tcp_keepalive='1'
			uci set uhttpd.rvpn.rfc1918_filter='0'
			uci set uhttpd.rvpn.max_requests='40'
			uci commit uhttpd
			uci set rvpn.main.zapret_enabled='0'
			uci set rvpn.main.vpn_enabled='0'
			if [ -f /usr/lib/rvpn/common.sh ]; then
				# shellcheck disable=SC1091
				. /usr/lib/rvpn/common.sh
				ensure_ui_secret >/dev/null 2>&1 || true
			fi
			uci commit rvpn
			/etc/init.d/uhttpd restart 2>/dev/null || true
			/etc/init.d/rvpn enable
			/etc/init.d/rvpn stop 2>/dev/null || true
		}
	fi
	skvoz_postinst
}

main() {
	[ "$(id -u)" -eq 0 ] || die "run as root on the router"

	install_dependencies
	obtain_files
	run_postinst

	log "install complete"
	log "UI: http://$(uci -q get network.lan.ipaddr 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}'):81/"
	log "ui_secret: $(uci -q get rvpn.main.ui_secret 2>/dev/null || echo unknown)"
	log "zapret and VPN are OFF — configure /etc/config/rvpn then enable layers"
	log "IMPORTANT: place architecture-matched nfqws at /opt/rvpn/nfqws (chmod +x)"
	log "  then: rvpnctl enable-zapret"
	log "VPN: edit node server/password, then: rvpnctl enable-vpn"
}

main "$@"
