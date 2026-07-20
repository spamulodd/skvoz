#!/bin/sh
# Auto-download nfqws from bol-van/zapret GitHub releases.

[ "${RVPN_NFQWS_FETCH_SOURCED:-0}" = "1" ] && return 0
RVPN_NFQWS_FETCH_SOURCED=1

. /usr/lib/rvpn/common.sh

NFQWS_PENDING=$RVPN_RUN/nfqws_fetch.pending

nfqws_arch_id() {
	m=$(uname -m 2>/dev/null)
	case "$m" in
	aarch64|x86_64|mips|mipsel|armv7l)
		echo "$m"
		return 0
		;;
	esac

	a=""
	if command -v opkg >/dev/null 2>&1; then
		a=$(opkg print-architecture 2>/dev/null | awk '{print $2}' | grep -E 'mips|arm|aarch64|x86_64' | head -n 1)
	elif command -v apk >/dev/null 2>&1; then
		a=$(apk --print-arch 2>/dev/null)
	fi

	case "$a" in
	*aarch64*) echo "aarch64" ;;
	*x86_64*) echo "x86_64" ;;
	*mipsel*) echo "mipsel" ;;
	*mips*) echo "mips" ;;
	*armv7*) echo "armv7l" ;;
	*arm*) echo "armv7l" ;;
	*)
		case "$m" in
		*mips64*) echo "mips" ;;
		*mips*) echo "mips" ;;
		*) echo "$m" ;;
		esac
		;;
	esac
}

nfqws_github_reachable() {
	rvpn_curl -sS --connect-timeout 4 --max-time 12 -o /dev/null -w '%{http_code}' \
		"https://api.github.com/repos/bol-van/zapret/releases/latest" 2>/dev/null | grep -qE '^(200|301|302)$'
}

nfqws_fetch_pending_clear() {
	rm -f "$NFQWS_PENDING" 2>/dev/null || true
}

nfqws_fetch_run() {
	arch=$(nfqws_arch_id)
	if [ -z "$arch" ]; then
		log "nfqws_fetch: cannot determine architecture"
		return 1
	fi

	mkdir -p "$RVPN_RUN"
	
	api_url="https://api.github.com/repos/bol-van/zapret/releases/latest"
	mirror_api_url="https://ghproxy.com/https://api.github.com/repos/bol-van/zapret/releases/latest"
	
	download_url=""
	
	json=$(rvpn_curl -sS --connect-timeout 5 --max-time 15 "$api_url" 2>/dev/null)
	if [ -z "$json" ]; then
		json=$(rvpn_curl -sS --connect-timeout 5 --max-time 15 "$mirror_api_url" 2>/dev/null)
	fi
	
	if [ -z "$json" ]; then
		log "nfqws_fetch: GitHub API unreachable, marking pending (retry after VPN)"
		printf 'github_blocked\n' > "$NFQWS_PENDING"
		return 1
	fi
	
	# Extract browser_download_url
	download_url=$(echo "$json" | grep -o '"browser_download_url": *"[^"]*-openwrt-embedded\.tar\.gz"' | cut -d '"' -f 4 | head -n 1)
	
	if [ -z "$download_url" ]; then
		log "nfqws_fetch: could not find openwrt-embedded release asset"
		return 1
	fi
	
	tmp_dir=$RVPN_RUN/nfqws_tmp.$$
	mkdir -p "$tmp_dir"
	tar_file=$tmp_dir/zapret.tar.gz
	
	log "nfqws_fetch: downloading $download_url (proxy=$(rvpn_proxy_ready && echo on || echo off))"
	if ! rvpn_curl -sS --connect-timeout 5 --max-time 180 -L -o "$tar_file" "$download_url" 2>/dev/null; then
		mirror_download_url="https://ghproxy.com/$download_url"
		log "nfqws_fetch: download failed, trying mirror"
		if ! rvpn_curl -sS --connect-timeout 5 --max-time 180 -L -o "$tar_file" "$mirror_download_url" 2>/dev/null; then
			log "nfqws_fetch: download failed, marking pending"
			printf 'download_failed\n' > "$NFQWS_PENDING"
			rm -rf "$tmp_dir"
			return 1
		fi
	fi
	
	if ! tar -xzf "$tar_file" -C "$tmp_dir" 2>/dev/null; then
		log "nfqws_fetch: tar extraction failed"
		rm -rf "$tmp_dir"
		return 1
	fi
	
	# Locate nfqws binary in extracted files for the target arch
	# Usually zapret-*/binaries/openwrt/$arch/nfqws or similar, we can just find it
	nfqws_bin=$(find "$tmp_dir" -type f -name "nfqws" | grep "/$arch/" | head -n 1)
	if [ -z "$nfqws_bin" ]; then
		# Fallback to just finding any nfqws and hoping the directory structure is flat or we guess it
		nfqws_bin=$(find "$tmp_dir" -type f -name "nfqws" | grep "$arch" | head -n 1)
	fi
	
	if [ -z "$nfqws_bin" ]; then
		log "nfqws_fetch: could not find nfqws binary for arch $arch in archive"
		rm -rf "$tmp_dir"
		return 1
	fi
	
	mkdir -p /opt/rvpn /usr/share/rvpn/bin
	# Binary path must be /opt/rvpn/nfqws (file), not a directory
	if [ -d /opt/rvpn/nfqws ]; then
		rm -rf /opt/rvpn/nfqws
	fi
	if cp "$nfqws_bin" /opt/rvpn/nfqws; then
		chmod +x /opt/rvpn/nfqws
		cp -f /opt/rvpn/nfqws /usr/share/rvpn/bin/nfqws 2>/dev/null || true
		log "nfqws_fetch: successfully installed nfqws for $arch"
		nfqws_fetch_pending_clear
		rm -rf "$tmp_dir"
		return 0
	else
		log "nfqws_fetch: failed to copy nfqws binary"
		rm -rf "$tmp_dir"
		return 1
	fi
}

nfqws_after_vpn_ready() {
	if [ -f "$NFQWS_PENDING" ]; then
		log "nfqws_fetch: VPN up — retry nfqws fetch (was pending)"
		nfqws_fetch_run
		return $?
	fi
	return 0
}
