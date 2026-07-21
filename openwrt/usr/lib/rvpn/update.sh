#!/bin/sh
# Safe overlay update from spamulodd/skvoz GitHub releases.

[ "${RVPN_UPDATE_SOURCED:-0}" = "1" ] && return 0
RVPN_UPDATE_SOURCED=1

. /usr/lib/rvpn/common.sh

SKVOZ_REPO=${SKVOZ_REPO:-spamulodd/skvoz}
UPDATE_VERSION_FILE=/usr/share/rvpn/VERSION
UPDATE_EDITION_FILE=/usr/share/rvpn/EDITION

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

# Pick browser_download_url from release JSON for edition (with fallbacks).
update_pick_asset_url() {
	json=$1
	ed=$2
	url=
	for try in "$ed" full all standard slim tiny; do
		url=$(printf '%s' "$json" | grep -o "\"browser_download_url\": *\"[^\"]*skvoz-[^\"]*-${try}\\.tar\\.gz\"" | head -1 | cut -d '"' -f 4)
		[ -n "$url" ] && break
	done
	[ -n "$url" ] || url=$(printf '%s' "$json" | grep -o '"browser_download_url": *"[^"]*skvoz-[^"]*\.tar\.gz"' | head -1 | cut -d '"' -f 4)
	echo "$url"
}

update_remote_version() {
	# Fetch latest release tag from GitHub API (short timeouts — CGI must not hang)
	api_url="https://api.github.com/repos/$SKVOZ_REPO/releases/latest"
	body=$(rvpn_curl -sS --connect-timeout 4 --max-time 12 "$api_url" 2>/dev/null) || body=
	if [ -z "$body" ]; then
		body=$(rvpn_curl -sS --connect-timeout 4 --max-time 12 \
			"https://ghproxy.com/$api_url" 2>/dev/null) || body=
	fi
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
	cur_n=$(echo "$current" | sed 's/^v//')
	rem_n=$(echo "$remote" | sed 's/^v//')
	if [ "$cur_n" != "$rem_n" ]; then
		has_update=1
	fi

	printf '{"ok":1,"status":"ok","current":"%s","remote":"%s","edition":"%s","has_update":%d,"proxy":%s}\n' \
		"$(json_escape "$current")" "$(json_escape "$remote")" "$(json_escape "$ed")" "$has_update" "$proxy"
	return 0
}

update_run() {
	mkdir -p "$RVPN_RUN"
	ed=$(update_current_edition)
	
	api_url="https://api.github.com/repos/$SKVOZ_REPO/releases/latest"
	json=$(rvpn_curl -sS --connect-timeout 5 --max-time 15 "$api_url" 2>/dev/null)
	
	if [ -z "$json" ]; then
		printf 'github_blocked\n' >"$RVPN_RUN/update.pending" 2>/dev/null || true
		printf '{"status":"error","message":"GitHub API unreachable — enable VPN then retry (update via proxy)"}\n'
		return 1
	fi
	
	download_url=$(update_pick_asset_url "$json" "$ed")
	
	if [ -z "$download_url" ]; then
		printf '{"status":"error","message":"could not find skvoz-*-%s.tar.gz release asset"}\n' "$ed"
		return 1
	fi
	log "update: edition=$ed url=$download_url proxy=$(rvpn_proxy_ready && echo on || echo off)"
	
	tmp_dir=$RVPN_RUN/update_tmp.$$
	mkdir -p "$tmp_dir"
	tar_file=$tmp_dir/update.tar.gz
	
	if ! rvpn_curl -sS --connect-timeout 5 --max-time 180 -L -o "$tar_file" "$download_url" 2>/dev/null; then
		mirror_download_url="https://ghproxy.com/$download_url"
		if ! rvpn_curl -sS --connect-timeout 5 --max-time 180 -L -o "$tar_file" "$mirror_download_url" 2>/dev/null; then
			printf 'download_failed\n' >"$RVPN_RUN/update.pending" 2>/dev/null || true
			printf '{"status":"error","message":"download failed — enable VPN and retry"}\n'
			rm -rf "$tmp_dir"
			return 1
		fi
	fi
	rm -f "$RVPN_RUN/update.pending" 2>/dev/null || true
	
	if ! tar -xzf "$tar_file" -C "$tmp_dir" 2>/dev/null; then
		printf '{"status":"error","message":"tar extraction failed"}\n'
		rm -rf "$tmp_dir"
		return 1
	fi
	
	# The tarball usually has the openwrt structure inside, e.g. openwrt/usr/... or just usr/...
	# We find the root of the extracted files
	extract_root="$tmp_dir"
	if [ -d "$tmp_dir/openwrt" ]; then
		extract_root="$tmp_dir/openwrt"
	fi
	
	# Helper to copy directory contents safely
	copy_safe() {
		src_dir=$1
		dst_dir=$2
		if [ -d "$src_dir" ]; then
			mkdir -p "$dst_dir"
			find "$src_dir" -type f > "$tmp_dir/copy_list"
			while read -r f; do
				rel_path=${f#$src_dir/}
				
				if [ "$dst_dir/$rel_path" = "/etc/config/rvpn" ]; then
					continue
				fi
				if echo "$rel_path" | grep -q '\-user\.txt$'; then
					continue
				fi
				
				dst_file="$dst_dir/$rel_path"
				mkdir -p "$(dirname "$dst_file")"
				cp -f "$f" "$dst_file"
				echo "\"$(json_escape "$dst_file")\"" >> "$tmp_dir/written_files"
			done < "$tmp_dir/copy_list"
		fi
	}
	
	: > "$tmp_dir/written_files"
	
	# Copy ONLY allowed paths
	copy_safe "$extract_root/usr/lib/rvpn" "/usr/lib/rvpn"
	copy_safe "$extract_root/www/rvpn" "/www/rvpn"
	copy_safe "$extract_root/usr/share/rvpn" "/usr/share/rvpn"
	
	if [ -f "$extract_root/etc/init.d/rvpn" ]; then
		mkdir -p /etc/init.d
		cp -f "$extract_root/etc/init.d/rvpn" /etc/init.d/rvpn
		echo "\"/etc/init.d/rvpn\"" >> "$tmp_dir/written_files"
	fi
	
	if [ -f "$extract_root/usr/bin/rvpnctl" ]; then
		mkdir -p /usr/bin
		cp -f "$extract_root/usr/bin/rvpnctl" /usr/bin/rvpnctl
		echo "\"/usr/bin/rvpnctl\"" >> "$tmp_dir/written_files"
	fi
	
	written_files=$(paste -sd, "$tmp_dir/written_files" 2>/dev/null || cat "$tmp_dir/written_files" | tr '\n' ',' | sed 's/,$//')

	
	# Chmod + strip Windows CRLF (breaks ash on OpenWrt)
	chmod +x /usr/lib/rvpn/*.sh /etc/init.d/rvpn /usr/bin/rvpnctl /www/rvpn/cgi-bin/* 2>/dev/null || true
	for f in /usr/lib/rvpn/*.sh /etc/init.d/rvpn /usr/bin/rvpnctl /www/rvpn/cgi-bin/rvpn.cgi; do
		[ -f "$f" ] || continue
		sed -i 's/\r$//' "$f" 2>/dev/null || true
	done

	# Optionally call nfqws_fetch_run and zapret_sync_run if available
	if [ -f /usr/lib/rvpn/nfqws-fetch.sh ]; then
		. /usr/lib/rvpn/nfqws-fetch.sh
		if command -v nfqws_fetch_run >/dev/null 2>&1; then
			nfqws_fetch_run >/dev/null 2>&1 || true
		fi
	fi
	
	if [ -f /usr/lib/rvpn/zapret-sync.sh ]; then
		. /usr/lib/rvpn/zapret-sync.sh
		if command -v zapret_sync_run >/dev/null 2>&1; then
			zapret_sync_run >/dev/null 2>&1 || true
		fi
	fi
	
	rm -rf "$tmp_dir"
	
	printf '{"status":"ok","message":"update successful","files":[%s]}\n' "$written_files"
	return 0
}
