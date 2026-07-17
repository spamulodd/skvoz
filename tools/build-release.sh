#!/bin/sh
# Build arch-independent Skvoz release tarball from openwrt/ tree.
# Usage: tools/build-release.sh [version]
# Output: dist/skvoz-<version>-all.tar.gz

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
OPENWRT_DIR="$ROOT_DIR/openwrt"
DIST_DIR="$ROOT_DIR/dist"

default_version() {
	if [ -f "$ROOT_DIR/package/skvoz/Makefile" ]; then
		sed -n 's/^PKG_VERSION:=//p' "$ROOT_DIR/package/skvoz/Makefile" | head -1
	else
		echo "1.0.0"
	fi
}

VERSION=${1:-$(default_version)}
VERSION=${VERSION#v}

if [ ! -d "$OPENWRT_DIR" ]; then
	echo "error: missing openwrt/ tree at $OPENWRT_DIR" >&2
	exit 1
fi

mkdir -p "$DIST_DIR"
OUT="$DIST_DIR/skvoz-${VERSION}-all.tar.gz"

(
	cd "$OPENWRT_DIR"
	# Archive root = openwrt/ contents (etc/, usr/, www/)
	tar czf "$OUT" .
)

echo "Built: $OUT"
echo "Note: nfqws is not included; install separately to /opt/rvpn/nfqws"
