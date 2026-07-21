#!/bin/sh
# Safe overlay update from spamulodd/skvoz GitHub releases.
# Requires sha256 of the tarball (GitHub asset digest and/or SHA256SUMS).

[ "${RVPN_UPDATE_SOURCED:-0}" = "1" ] && return 0
RVPN_UPDATE_SOURCED=1

. /usr/lib/rvpn/common.sh

SKVOZ_REPO=${SKVOZ_REPO:-spamulodd/skvoz}
UPDATE_VERSION_FILE=/usr/share/rvpn/VERSION
UPDATE_EDITION_FILE=/usr/share/rvpn/EDITION
UPDATE_STATUS_FILE=$RVPN_RUN/update.status

# Compare dotted versions: 1 if $1 > $2, 0 if equal, -1 if $1 < $2. Non-numeric → string cmp.
update_version_cmp() {
	a=$(printf '%s' "$1" | sed 's/^v//;s/\r//g;s/[^0-9A-Za-z.].*//')
	b=$(printf '%s' "$2" | sed 's/^v//;s/\r//g;s/[^0-9A-Za-z.].*//')
	[ -n "$a" ] || a=0
	[ -n "$b" ] || b=0
	if [ "$a" = "$b" ]; then
		echo 0
		return 0
	fi
	# Pure dotted-numeric?
	case "$a$b" in
	*[!0-9.]*)
		[ "$a" \> "$b" ] && echo 1 || echo -1
		return 0
		;;
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
		x=${pair%%:*}
		y=${pair#*:}
		case "$x" in ''|*[!0-9]*) x=0 ;; esac
		case "$y" in ''|*[!0-9]*) y=0 ;; esac
		if [ "$x" -gt "$y" ]; then echo 1; return 0; fi
		if [ "$x" -lt "$y" ]; then echo -1; return 0; fi
	done
	echo 0
}

update_status_set() {
	# state message [extra=val ...]
	st=$1
	msg=${2:-}
	mkdir -p "$RVPN_RUN"
	{
		printf 'state=%s\n' "$st"
		printf 'message=%s\n' "$msg"
		printf 'ts=%s\n' "$(date +%s 2>/dev/null || echo 0)"
		shift 2 2>/dev/null || true
		for kv in "$@"; do
			[ -n "$kv" ] && printf '%s\n' "$kv"
		done
	} >"$UPDATE_STATUS_FILE"
}

update_status_json() {
	st=idle
	msg=
	ts=0
	ver=
	if [ -f "$UPDATE_STATUS_FILE" ]; then
		# shellcheck disable=SC2162
		while IFS='=' read -r k v; do
			case "$k" in
			state) st=$v ;;
			message) msg=$v ;;
			ts) ts=$v ;;
			version) ver=$v ;;
			esac
		done <"$UPDATE_STATUS_FILE"
	fi
	[ -n "$st" ] || st=idle
	printf '{"ok":1,"state":"%s","message":"%s","ts":"%s","version":"%s"}\n' \
		"$(json_escape "$st")" "$(json_escape "$msg")" "$(json_escape "$ts")" "$(json_escape "$ver")"
}

update_current_version() {
	if [ -f "$UPDATE_VERSION_FILE" ]; then
		tr -d '\r\n' <"$UPDATE_VERSION_FILE" 2>/dev/null
	else
		echo "unknown"
	fi
}

update_current_edition() {
	ed=
	[ -f "$UPDATE_EDITION_FILE" ] && ed=$(cat "$UPDATE_EDITION_FILE" 2>/dev/null)
	[ -n "$ed" ] || ed=${SKVOZ_EDITION:-standard}
	case "$ed" in tiny|slim|standard|full|all) ;; *) ed=standard ;; esac
	[ "$ed" = "all" ] && ed=full
	echo "$ed"
}

# Fetch latest release JSON (GitHub only — no third-party API mirror).
update_fetch_release_json() {
	api_url="https://api.github.com/repos/$SKVOZ_REPO/releases/latest"
	rvpn_curl -sS --connect-timeout 4 --max-time 12 "$api_url" 2>/dev/null || true
}

# Pick browser_download_url + optional sha256 digest for edition.
# Prints: url<TAB>sha256_or_empty
update_pick_asset() {
	json=$1
	ed=$2
	url=
	digest=
	for try in "$ed" full all standard slim tiny; do
		# Prefer line that also has digest nearby — parse with awk over assets
		line=$(printf '%s' "$json" | tr '}' '\n' | grep -F "skvoz-" | grep -F "-${try}.tar.gz" | head -1)
		[ -n "$line" ] || continue
		url=$(printf '%s' "$line" | grep -o '"browser_download_url": *"[^"]*"' | head -1 | cut -d '"' -f 4)
		digest=$(printf '%s' "$line" | grep -o '"digest": *"sha256:[^"]*"' | head -1 | cut -d '"' -f 4 | sed 's/^sha256://')
		[ -n "$url" ] && break
	done
	if [ -z "$url" ]; then
		url=$(printf '%s' "$json" | grep -o '"browser_download_url": *"[^"]*skvoz-[^"]*\.tar\.gz"' | head -1 | cut -d '"' -f 4)
		digest=
	fi
	printf '%s\t%s\n' "$url" "$digest"
}

# Backward-compatible: URL only
update_pick_asset_url() {
	json=$1
	ed=$2
	update_pick_asset "$json" "$ed" | cut -f1
}

update_remote_version() {
	body=$(update_fetch_release_json)
	tag=$(printf '%s' "$body" | grep -o '"tag_name": *"[^"]*"' | head -n 1 | cut -d '"' -f 4)
	if [ -n "$tag" ]; then
		echo "$tag" | sed 's/^v//;s/\r//g'
	else
		echo ""
	fi
}

update_check_json() {
	current=$(update_current_version | tr -d '\r\n ')
	[ -n "$current" ] || current=unknown
	remote=$(update_remote_version | tr -d '\r\n ')
	ed=$(update_current_edition | tr -d '\r\n ')
	proxy=0
	rvpn_proxy_ready && proxy=1

	if [ -z "$remote" ]; then
		printf '{"ok":0,"status":"error","message":"GitHub недоступен — включите VPN и повторите","current":"%s","remote":"","edition":"%s","has_update":0,"proxy":%s}\n' \
			"$(json_escape "$current")" "$(json_escape "$ed")" "$proxy"
		return 0
	fi

	has_update=0
	cmp=$(update_version_cmp "$remote" "$current")
	[ "$cmp" = "1" ] && has_update=1

	printf '{"ok":1,"status":"ok","current":"%s","remote":"%s","edition":"%s","has_update":%d,"proxy":%s}\n' \
		"$(json_escape "$current")" "$(json_escape "$remote")" "$(json_escape "$ed")" "$has_update" "$proxy"
	return 0
}

update_file_sha256() {
	f=$1
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$f" 2>/dev/null | awk '{print $1; exit}'
	elif command -v openssl >/dev/null 2>&1; then
		openssl dgst -sha256 "$f" 2>/dev/null | awk '{print $NF; exit}'
	else
		echo ""
	fi
}

# Resolve expected sha256: prefer API digest, else SHA256SUMS asset in same release.
update_resolve_sha256() {
	json=$1
	asset_url=$2
	api_digest=$3
	basename=$(basename "$asset_url")

	if [ -n "$api_digest" ]; then
		echo "$api_digest"
		return 0
	fi

	sums_url=$(printf '%s' "$json" | grep -o '"browser_download_url": *"[^"]*SHA256SUMS[^"]*"' | head -1 | cut -d '"' -f 4)
	[ -n "$sums_url" ] || sums_url=$(printf '%s' "$json" | grep -o '"browser_download_url": *"[^"]*sha256sums[^"]*"' | head -1 | cut -d '"' -f 4)
	[ -n "$sums_url" ] || {
		echo ""
		return 1
	}

	tmp=$RVPN_RUN/sha256sums.$$
	if ! rvpn_curl -sS --connect-timeout 5 --max-time 30 -L -o "$tmp" "$sums_url" 2>/dev/null; then
		rm -f "$tmp"
		echo ""
		return 1
	fi
	# lines: <hash>  <filename>  or  <hash> *<filename>
	got=$(awk -v b="$basename" '
		$2 == b || $2 == ("*" b) || $2 ~ ("/" b "$") { print $1; exit }
	' "$tmp")
	rm -f "$tmp"
	echo "$got"
}

# Reject tar members with absolute paths or .. components.
update_tar_members_safe() {
	tar_file=$1
	tar -tzf "$tar_file" 2>/dev/null | awk '
		$0 ~ /^\// { exit 1 }
		{
			n = split($0, a, "/")
			for (i = 1; i <= n; i++) if (a[i] == "..") exit 1
		}
	'
}

update_copy_safe() {
	src_dir=$1
	dst_dir=$2
	list_file=$3
	written=$4
	if [ ! -d "$src_dir" ]; then
		return 0
	fi
	mkdir -p "$dst_dir"
	find "$src_dir" -type f >"$list_file"
	while IFS= read -r f || [ -n "$f" ]; do
		[ -n "$f" ] || continue
		rel_path=${f#"$src_dir"/}
		# Path traversal / weird names
		case "$rel_path" in
		''|/*|*\..*)
			case "$rel_path" in
			*..*) continue ;;
			/*) continue ;;
			esac
			;;
		esac
		printf '%s\n' "$rel_path" | tr '/' '\n' | grep -qx '\.\.' && continue

		if [ "$dst_dir/$rel_path" = "/etc/config/rvpn" ]; then
			continue
		fi
		# Preserve user overlays and allowlist across OTA
		case "$rel_path" in
		*-user.txt|*/adblock-allow.txt|adblock-allow.txt) continue ;;
		esac

		dst_file="$dst_dir/$rel_path"
		mkdir -p "$(dirname "$dst_file")"
		cp -f "$f" "$dst_file"
		echo "\"$(json_escape "$dst_file")\"" >>"$written"
	done <"$list_file"
}

# Only (re)fetch nfqws when missing or not a working binary.
update_nfqws_needed() {
	bin=
	[ -x /opt/rvpn/nfqws ] && bin=/opt/rvpn/nfqws
	[ -z "$bin" ] && [ -x /usr/share/rvpn/bin/nfqws ] && bin=/usr/share/rvpn/bin/nfqws
	[ -n "$bin" ] || return 0
	# ELF / executable smoke: file exists and is non-empty
	[ -s "$bin" ] || return 0
	return 1
}

update_run() {
	mkdir -p "$RVPN_RUN"
	ed=$(update_current_edition)
	update_status_set running "downloading release" "edition=$ed"

	json=$(update_fetch_release_json)

	if [ -z "$json" ]; then
		printf 'github_blocked\n' >"$RVPN_RUN/update.pending" 2>/dev/null || true
		update_status_set error "GitHub API unreachable — enable VPN then retry"
		printf '{"status":"error","message":"GitHub API unreachable — enable VPN then retry (update via proxy)"}\n'
		return 1
	fi

	pick=$(update_pick_asset "$json" "$ed")
	download_url=$(printf '%s' "$pick" | cut -f1)
	api_digest=$(printf '%s' "$pick" | cut -f2)

	if [ -z "$download_url" ]; then
		update_status_set error "could not find release asset"
		printf '{"status":"error","message":"could not find skvoz-*-%s.tar.gz release asset"}\n' "$ed"
		return 1
	fi

	expect_sha=$(update_resolve_sha256 "$json" "$download_url" "$api_digest")
	if [ -z "$expect_sha" ]; then
		update_status_set error "missing release checksum (SHA256SUMS / digest)"
		printf '{"status":"error","message":"release has no sha256 digest or SHA256SUMS — refusing update"}\n'
		return 1
	fi

	log "update: edition=$ed url=$download_url sha256=${expect_sha} proxy=$(rvpn_proxy_ready && echo on || echo off)"
	update_status_set running "downloading tarball" "edition=$ed"

	tmp_dir=$RVPN_RUN/update_tmp.$$
	mkdir -p "$tmp_dir"
	tar_file=$tmp_dir/update.tar.gz

	dl_ok=0
	if rvpn_curl -sS --connect-timeout 5 --max-time 180 -L -o "$tar_file" "$download_url" 2>/dev/null; then
		dl_ok=1
	else
		# Mirror only for bytes; integrity still verified against GitHub checksum
		mirror_download_url="https://ghproxy.com/$download_url"
		update_status_set running "downloading via mirror"
		if rvpn_curl -sS --connect-timeout 5 --max-time 180 -L -o "$tar_file" "$mirror_download_url" 2>/dev/null; then
			dl_ok=1
		fi
	fi

	if [ "$dl_ok" != 1 ]; then
		printf 'download_failed\n' >"$RVPN_RUN/update.pending" 2>/dev/null || true
		update_status_set error "download failed"
		printf '{"status":"error","message":"download failed — enable VPN and retry"}\n'
		rm -rf "$tmp_dir"
		return 1
	fi
	rm -f "$RVPN_RUN/update.pending" 2>/dev/null || true

	got_sha=$(update_file_sha256 "$tar_file")
	if [ -z "$got_sha" ]; then
		update_status_set error "sha256sum unavailable on device"
		printf '{"status":"error","message":"cannot verify checksum (no sha256sum/openssl)"}\n'
		rm -rf "$tmp_dir"
		return 1
	fi
	if [ "$got_sha" != "$expect_sha" ]; then
		update_status_set error "checksum mismatch"
		log "update: sha256 mismatch expect=$expect_sha got=$got_sha"
		printf '{"status":"error","message":"checksum mismatch — refusing to install"}\n'
		rm -rf "$tmp_dir"
		return 1
	fi

	update_status_set running "extracting"
	if ! update_tar_members_safe "$tar_file"; then
		update_status_set error "unsafe tar members rejected"
		printf '{"status":"error","message":"tar contains unsafe paths"}\n'
		rm -rf "$tmp_dir"
		return 1
	fi

	if ! tar -xzf "$tar_file" -C "$tmp_dir" 2>/dev/null; then
		update_status_set error "tar extraction failed"
		printf '{"status":"error","message":"tar extraction failed"}\n'
		rm -rf "$tmp_dir"
		return 1
	fi

	# Second pass: reject any extracted path escaping tmp_dir via ..
	if find "$tmp_dir" -name '..' 2>/dev/null | grep -q .; then
		update_status_set error "path escape in extract"
		rm -rf "$tmp_dir"
		printf '{"status":"error","message":"unsafe extract layout"}\n'
		return 1
	fi

	extract_root="$tmp_dir"
	if [ -d "$tmp_dir/openwrt" ]; then
		extract_root="$tmp_dir/openwrt"
	fi

	: >"$tmp_dir/written_files"
	update_copy_safe "$extract_root/usr/lib/rvpn" "/usr/lib/rvpn" "$tmp_dir/copy_list" "$tmp_dir/written_files"
	update_copy_safe "$extract_root/www/rvpn" "/www/rvpn" "$tmp_dir/copy_list" "$tmp_dir/written_files"
	update_copy_safe "$extract_root/usr/share/rvpn" "/usr/share/rvpn" "$tmp_dir/copy_list" "$tmp_dir/written_files"

	if [ -f "$extract_root/etc/init.d/rvpn" ]; then
		mkdir -p /etc/init.d
		cp -f "$extract_root/etc/init.d/rvpn" /etc/init.d/rvpn
		echo "\"/etc/init.d/rvpn\"" >>"$tmp_dir/written_files"
	fi

	if [ -f "$extract_root/usr/bin/rvpnctl" ]; then
		mkdir -p /usr/bin
		cp -f "$extract_root/usr/bin/rvpnctl" /usr/bin/rvpnctl
		echo "\"/usr/bin/rvpnctl\"" >>"$tmp_dir/written_files"
	fi

	written_files=$(paste -sd, "$tmp_dir/written_files" 2>/dev/null || tr '\n' ',' <"$tmp_dir/written_files" | sed 's/,$//')

	chmod +x /usr/lib/rvpn/*.sh /etc/init.d/rvpn /usr/bin/rvpnctl /www/rvpn/cgi-bin/* 2>/dev/null || true
	for f in /usr/lib/rvpn/*.sh /etc/init.d/rvpn /usr/bin/rvpnctl /www/rvpn/cgi-bin/rvpn.cgi; do
		[ -f "$f" ] || continue
		sed -i 's/\r$//' "$f" 2>/dev/null || true
	done

	# nfqws: only if missing/broken
	if update_nfqws_needed && [ -f /usr/lib/rvpn/nfqws-fetch.sh ]; then
		update_status_set running "fetching nfqws"
		# shellcheck source=/dev/null
		. /usr/lib/rvpn/nfqws-fetch.sh
		if command -v nfqws_fetch_run >/dev/null 2>&1; then
			nfqws_fetch_run >/dev/null 2>&1 || true
		fi
	fi

	if [ -f /usr/lib/rvpn/zapret-sync.sh ]; then
		# shellcheck source=/dev/null
		. /usr/lib/rvpn/zapret-sync.sh
		if command -v zapret_sync_run >/dev/null 2>&1; then
			update_status_set running "zapret sync"
			zapret_sync_run >/dev/null 2>&1 || true
		fi
	fi

	newver=$(update_current_version)
	rm -rf "$tmp_dir"

	update_status_set ok "update successful" "version=$newver"
	printf '{"status":"ok","message":"update successful","files":[%s]}\n' "$written_files"
	return 0
}
