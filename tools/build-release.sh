#!/bin/sh
# Build Skvoz release tarballs: tiny / slim / standard / full
# Usage: tools/build-release.sh [version]
# Output: dist/skvoz-<version>-{tiny,slim,standard,full}.tar.gz
#         dist/RELEASE-NOTES-<version>.md

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
OPENWRT_DIR="$ROOT_DIR/openwrt"
DIST_DIR="$ROOT_DIR/dist"

default_version() {
	if [ -f "$ROOT_DIR/package/skvoz/Makefile" ]; then
		sed -n 's/^PKG_VERSION:=//p' "$ROOT_DIR/package/skvoz/Makefile" | head -1
	elif [ -f "$OPENWRT_DIR/usr/share/rvpn/VERSION" ]; then
		cat "$OPENWRT_DIR/usr/share/rvpn/VERSION"
	else
		echo "0.2.0"
	fi
}

VERSION=${1:-$(default_version)}
VERSION=${VERSION#v}

if [ ! -d "$OPENWRT_DIR" ]; then
	echo "error: missing openwrt/ tree at $OPENWRT_DIR" >&2
	exit 1
fi

mkdir -p "$DIST_DIR" "$OPENWRT_DIR/usr/share/rvpn"
echo "$VERSION" >"$OPENWRT_DIR/usr/share/rvpn/VERSION"

# Staging copy — never pack gitignored nfqws / raw bats into releases
STAGE=$DIST_DIR/stage-$$
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT INT HUP TERM

rm -rf "$STAGE"
mkdir -p "$STAGE"
# Prefer rsync; fallback tar pipe
if command -v rsync >/dev/null 2>&1; then
	rsync -a \
		--exclude 'usr/share/rvpn/bin/nfqws' \
		--exclude 'usr/share/rvpn/zapret-strategies/_raw_bats' \
		--exclude '.git' \
		"$OPENWRT_DIR/" "$STAGE/"
else
	( cd "$OPENWRT_DIR" && tar cf - \
		--exclude='usr/share/rvpn/bin/nfqws' \
		--exclude='usr/share/rvpn/zapret-strategies/_raw_bats' \
		. ) | ( cd "$STAGE" && tar xf - )
fi

# --- helpers ---
kb_of() {
	# $1 = tar.gz path
	if command -v wc >/dev/null 2>&1; then
		wc -c <"$1" | awk '{printf "%.1f", $1/1024}'
	else
		echo "?"
	fi
}

pack_edition() {
	ed=$1
	src=$2
	out="$DIST_DIR/skvoz-${VERSION}-${ed}.tar.gz"
	( cd "$src" && tar czf "$out" . )
	echo "$out"
}

# Start from full stage, then prune into copies
FULL=$STAGE
SLIM_SRC=$DIST_DIR/ed-slim-$$
STD_SRC=$DIST_DIR/ed-std-$$
TINY_SRC=$DIST_DIR/ed-tiny-$$
rm -rf "$SLIM_SRC" "$STD_SRC" "$TINY_SRC"
cp -a "$FULL" "$STD_SRC"
cp -a "$FULL" "$SLIM_SRC"
cp -a "$FULL" "$TINY_SRC"

# ---- standard: drop long docs ----
rm -f \
	"$STD_SRC/usr/share/rvpn/rules/ROUTING.md" \
	"$STD_SRC/usr/share/rvpn/rules/SUBSCRIPTIONS.md" \
	"$STD_SRC/usr/share/rvpn/rules/README.md" \
	2>/dev/null || true

# ---- slim: few strategies + essential lists/fake ----
STRAT="$SLIM_SRC/usr/share/rvpn/zapret-strategies"
if [ -d "$STRAT" ]; then
	keep='general_alt11.strategy general.strategy general_simple_fake.strategy general_fake_tls_auto.strategy INDEX META.json'
	for f in "$STRAT"/*.strategy; do
		[ -f "$f" ] || continue
		base=$(basename "$f")
		keep_it=0
		for k in $keep; do
			[ "$base" = "$k" ] && keep_it=1 && break
		done
		[ "$keep_it" = 1 ] || rm -f "$f"
	done
	# rewrite INDEX
	: >"$STRAT/INDEX"
	for f in "$STRAT"/*.strategy; do
		[ -f "$f" ] || continue
		basename "$f" .strategy >>"$STRAT/INDEX"
	done
	rm -f "$STRAT/lists/list-google.txt" "$STRAT/lists/ipset-all.txt" "$STRAT/lists/ipset-exclude.txt" 2>/dev/null || true
fi
rm -f \
	"$SLIM_SRC/usr/share/rvpn/rules/ROUTING.md" \
	"$SLIM_SRC/usr/share/rvpn/rules/SUBSCRIPTIONS.md" \
	"$SLIM_SRC/usr/share/rvpn/rules/README.md" \
	"$SLIM_SRC/usr/share/rvpn/fake/quic_initial_dbankcloud_ru.bin" \
	"$SLIM_SRC/usr/share/rvpn/fake/tls_clienthello_4pda_to.bin" \
	2>/dev/null || true

# ---- tiny: single strategy, minimal extras ----
STRAT="$TINY_SRC/usr/share/rvpn/zapret-strategies"
if [ -d "$STRAT" ]; then
	for f in "$STRAT"/*.strategy; do
		[ -f "$f" ] || continue
		case "$(basename "$f")" in
		general_alt11.strategy) ;;
		*) rm -f "$f" ;;
		esac
	done
	echo "general_alt11" >"$STRAT/INDEX"
	printf '%s\n' '{"source":"Flowseal","strategies":["general_alt11"],"edition":"tiny"}' >"$STRAT/META.json"
	rm -rf "$STRAT/lists" 2>/dev/null || true
	mkdir -p "$STRAT/lists"
	# tiny placeholder — real lists via zapret-sync after VPN
	printf '%s\n' '# downloaded after VPN: rvpnctl zapret-sync' >"$STRAT/lists/list-general.txt"
fi
rm -f \
	"$TINY_SRC/usr/share/rvpn/rules/ROUTING.md" \
	"$TINY_SRC/usr/share/rvpn/rules/SUBSCRIPTIONS.md" \
	"$TINY_SRC/usr/share/rvpn/rules/README.md" \
	"$TINY_SRC/usr/share/rvpn/fake/quic_initial_www_google_com.bin" \
	"$TINY_SRC/usr/share/rvpn/fake/quic_initial_dbankcloud_ru.bin" \
	"$TINY_SRC/usr/share/rvpn/fake/tls_clienthello_4pda_to.bin" \
	"$TINY_SRC/usr/share/rvpn/rules/adblock-seed.txt" \
	2>/dev/null || true
# tiny: empty adblock seed stub (adblock optional)
printf '%s\n' '# optional — enable adblock in UI; list via adblock-update' \
	>"$TINY_SRC/usr/share/rvpn/rules/adblock-seed.txt"

# Stamp edition marker
for ed_dir in "$FULL:$FULL" "$STD_SRC:standard" "$SLIM_SRC:slim" "$TINY_SRC:tiny"; do
	:
done
echo "full" >"$FULL/usr/share/rvpn/EDITION"
echo "standard" >"$STD_SRC/usr/share/rvpn/EDITION"
echo "slim" >"$SLIM_SRC/usr/share/rvpn/EDITION"
echo "tiny" >"$TINY_SRC/usr/share/rvpn/EDITION"

OUT_TINY=$(pack_edition tiny "$TINY_SRC")
OUT_SLIM=$(pack_edition slim "$SLIM_SRC")
OUT_STD=$(pack_edition standard "$STD_SRC")
OUT_FULL=$(pack_edition full "$FULL")

# Also alias -all → full for older docs
cp -f "$OUT_FULL" "$DIST_DIR/skvoz-${VERSION}-all.tar.gz"

NOTES=$DIST_DIR/RELEASE-NOTES-${VERSION}.md
{
	cat <<EOF
# Skvoz v${VERSION}

Гибрид **zapret + VPN (sing-box)** для OpenWrt. Установка одной командой, дальше мастер в UI.

## Установка

\`\`\`sh
# рекомендуем standard (баланс размер/функции)
SKVOZ_EDITION=standard curl -fsSL https://raw.githubusercontent.com/spamulodd/skvoz/main/tools/install.sh | sh
\`\`\`

После установки в консоли будут **UI URL** и **Password**. Откройте мастер.

Мало flash → \`SKVOZ_EDITION=tiny\` или \`slim\`. Есть запас / USB → \`full\`.

## Editions (что качать)

| Asset | Flash | Содержимое |
|-------|-------|------------|
| \`skvoz-${VERSION}-tiny.tar.gz\` (~$(kb_of "$OUT_TINY") KB) | 8–16 MB, впритык | 1 стратегия ALT11, минимальные списки; Flowseal/nfqws — после VPN |
| \`skvoz-${VERSION}-slim.tar.gz\` (~$(kb_of "$OUT_SLIM") KB) | 16–32 MB | 4 стратегии + list-general + основные fake |
| \`skvoz-${VERSION}-standard.tar.gz\` (~$(kb_of "$OUT_STD") KB) | обычный роутер | все стратегии Flowseal + lists + fake |
| \`skvoz-${VERSION}-full.tar.gz\` (~$(kb_of "$OUT_FULL") KB) | запас / флешка | standard + ROUTING.md / docs |
| \`skvoz-${VERSION}-all.tar.gz\` | alias | = **full** |

Подробности: [tools/release-editions.md](https://github.com/spamulodd/skvoz/blob/main/tools/release-editions.md)

## Важно

- **nfqws** в архивах нет — качается под архитектуру роутера при install / \`rvpnctl nfqws-fetch\`.
- Если GitHub режет провайдер: поставьте VPN в мастере → «Списки» / \`rvpnctl zapret-sync\`.
- Обновление без wipe конфига: \`rvpnctl update\` (подтянет тот же edition из VERSION/EDITION если задан).

## Размеры этой сборки

- tiny: $(kb_of "$OUT_TINY") KB
- slim: $(kb_of "$OUT_SLIM") KB
- standard: $(kb_of "$OUT_STD") KB
- full: $(kb_of "$OUT_FULL") KB

EOF
} >"$NOTES"

rm -rf "$SLIM_SRC" "$STD_SRC" "$TINY_SRC"

echo "Built:"
echo "  $OUT_TINY"
echo "  $OUT_SLIM"
echo "  $OUT_STD"
echo "  $OUT_FULL"
echo "  $DIST_DIR/skvoz-${VERSION}-all.tar.gz  (alias of full)"
echo "Notes: $NOTES"
echo ""
echo "Publish all assets:"
echo "  gh release create v${VERSION} \\"
echo "    \"$OUT_TINY\" \"$OUT_SLIM\" \"$OUT_STD\" \"$OUT_FULL\" \\"
echo "    \"$DIST_DIR/skvoz-${VERSION}-all.tar.gz\" \\"
echo "    --title \"v${VERSION}\" --notes-file \"$NOTES\""
