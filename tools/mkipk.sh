#!/bin/sh
# Build naive arch-independent .ipk for Skvoz (shell scripts + rules only).
# Usage: tools/mkipk.sh [version] [output-dir]
# Output: skvoz_<version>_all.ipk

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
OPENWRT_DIR="$ROOT_DIR/openwrt"
POSTINST="$SCRIPT_DIR/postinst.sh"

default_version() {
	if [ -f "$ROOT_DIR/package/skvoz/Makefile" ]; then
		sed -n 's/^PKG_VERSION:=//p' "$ROOT_DIR/package/skvoz/Makefile" | head -1
	else
		echo "1.0.0"
	fi
}

VERSION=${1:-$(default_version)}
VERSION=${VERSION#v}
OUT_DIR=${2:-$ROOT_DIR/dist}

if [ ! -d "$OPENWRT_DIR" ]; then
	echo "error: missing openwrt/ tree at $OPENWRT_DIR" >&2
	exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT HUP TERM

DATA="$WORK/data"
CONTROL="$WORK/control"
mkdir -p "$DATA" "$CONTROL"

install_file() {
	src=$1
	rel=$2
	mode=$3
	dest="$DATA/$rel"
	mkdir -p "$(dirname "$dest")"
	install -m "$mode" "$src" "$dest"
}

# Copy openwrt/ tree into ipk data root
find "$OPENWRT_DIR" -type f | while IFS= read -r f; do
	rel=${f#"$OPENWRT_DIR"/}
	case "$rel" in
	etc/init.d/*|usr/bin/*|usr/lib/rvpn/*.sh|www/rvpn/cgi-bin/*)
		mode=755
		;;
	*)
		mode=644
		;;
	esac
	install_file "$f" "$rel" "$mode"
done

cat >"$CONTROL/control" <<EOF
Package: skvoz
Version: ${VERSION}-1
Depends: libnetfilter-queue, kmod-nfnetlink-queue, kmod-nft-queue, kmod-nft-tproxy, curl, ca-bundle
Architecture: all
Maintainer: Skvoz
Section: net
Priority: optional
Description: Skvoz hybrid bypass (zapret + VPN) for OpenWrt.
 Arch-independent scripts and domain lists. nfqws binary not included.
EOF

{
	echo '#!/bin/sh'
	echo '[ -n "${IPKG_INSTROOT:-}" ] && exit 0'
	cat "$POSTINST"
	echo 'skvoz_postinst'
	echo 'exit 0'
} >"$CONTROL/postinst"
chmod 755 "$CONTROL/postinst"

cat >"$CONTROL/prerm" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT:-}" ] && exit 0
/etc/init.d/rvpn stop 2>/dev/null || true
/etc/init.d/rvpn disable 2>/dev/null || true
exit 0
EOF
chmod 755 "$CONTROL/prerm"

(
	cd "$WORK"
	tar czf control.tar.gz -C control .
	tar czf data.tar.gz -C data .
	printf '2.0\n' >debian-binary
)

mkdir -p "$OUT_DIR"
IPK="$OUT_DIR/skvoz_${VERSION}_all.ipk"
(
	cd "$WORK"
	tar czf "$IPK" ./debian-binary ./control.tar.gz ./data.tar.gz
)

echo "Built: $IPK"
echo "Install: opkg install $IPK"
