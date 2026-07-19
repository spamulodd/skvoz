#!/bin/sh
# DNS adblock via dnsmasq address=/domain/0.0.0.0 (runs before FakeIP forward).
. /usr/lib/rvpn/common.sh
. /usr/lib/rvpn/dns.sh

ADBLOCK_SEED=$RVPN_RULES/adblock-seed.txt
ADBLOCK_USER=$RVPN_RULES/adblock-user.txt
ADBLOCK_ALLOW=$RVPN_RULES/adblock-allow.txt
ADBLOCK_CACHE=$RVPN_RUN/adblock.cache.txt
ADBLOCK_CONF=$RVPN_RUN/adblock.dnsmasq
ADBLOCK_META=$RVPN_RUN/adblock.meta
ADBLOCK_LINK=/tmp/dnsmasq.d/rvpn-adblock.conf
ADBLOCK_DEFAULT_URL='https://small.oisd.nl/'

adblock_enabled() {
	[ "$(uci_get adblock_enabled)" = "1" ]
}

adblock_list_url() {
	u=$(uci_get adblock_list_url)
	[ -n "$u" ] || u=$ADBLOCK_DEFAULT_URL
	echo "$u"
}

# Extract hostnames from hosts file or domain list → stdout (one per line).
adblock_normalize_stream() {
	awk '
		function valid(h) {
			if (h ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) return 0
			if (h ~ /^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$/) return 1
			return 0
		}
		/^[[:space:]]*#/ { next }
		/^[[:space:]]*$/ { next }
		{
			gsub(/\r/, "")
			n = split($0, a, /[[:space:]]+/)
			h = ""
			if (n >= 2 && a[1] ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) h = a[2]
			else h = a[1]
			gsub(/^\*\./, "", h)
			h = tolower(h)
			if (valid(h)) print h
		}
	'
}

adblock_is_allowed() {
	host=$1
	[ -f "$ADBLOCK_ALLOW" ] || return 1
	# exact or suffix match against allow list entries
	while IFS= read -r a || [ -n "$a" ]; do
		a=$(echo "$a" | sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//' | tr 'A-Z' 'a-z')
		[ -n "$a" ] || continue
		[ "$host" = "$a" ] && return 0
		case "$host" in
		*."$a") return 0 ;;
		esac
	done <"$ADBLOCK_ALLOW"
	return 1
}

# Build merged domain list into $1 (raw hostnames).
adblock_build_domains() {
	out=$1
	tmp=$RVPN_RUN/adblock.build.$$
	mkdir -p "$RVPN_RUN"
	: >"$tmp"
	[ -f "$ADBLOCK_CACHE" ] && adblock_normalize_stream <"$ADBLOCK_CACHE" >>"$tmp"
	[ -f "$ADBLOCK_SEED" ] && adblock_normalize_stream <"$ADBLOCK_SEED" >>"$tmp"
	[ -f "$ADBLOCK_USER" ] && adblock_normalize_stream <"$ADBLOCK_USER" >>"$tmp"
	sort -u "$tmp" >"$tmp.u"
	: >"$out"
	while IFS= read -r h || [ -n "$h" ]; do
		[ -n "$h" ] || continue
		adblock_is_allowed "$h" && continue
		echo "$h" >>"$out"
	done <"$tmp.u"
	rm -f "$tmp" "$tmp.u"
}

adblock_generate_conf() {
	doms=$RVPN_RUN/adblock.domains.$$
	adblock_build_domains "$doms"
	n=$(wc -l <"$doms" | tr -d ' ')
	{
		echo "# Skvoz DNS adblock — generated $(date -u +%Y-%m-%dT%H:%MZ 2>/dev/null || date)"
		echo "# domains=$n"
		while IFS= read -r h || [ -n "$h" ]; do
			[ -n "$h" ] || continue
			# dnsmasq: block A/AAAA
			printf 'address=/%s/0.0.0.0\n' "$h"
		done <"$doms"
	} >"$ADBLOCK_CONF"
	rm -f "$doms"
	ts=$(date -u +%Y-%m-%dT%H:%MZ 2>/dev/null || date)
	printf 'domains=%s\nupdated=%s\nurl=%s\n' "$n" "$ts" "$(adblock_list_url)" >"$ADBLOCK_META"
	chmod 644 "$ADBLOCK_CONF" 2>/dev/null || true
	echo "$n"
}

adblock_fetch() {
	url=$(adblock_list_url)
	mkdir -p "$RVPN_RUN"
	raw=$RVPN_RUN/adblock.fetch.$$
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --connect-timeout 20 --max-time 180 -A 'skvoz-adblock/1.0' "$url" -o "$raw" || {
			rm -f "$raw"
			return 1
		}
	elif command -v wget >/dev/null 2>&1; then
		wget -qT 180 -U 'skvoz-adblock/1.0' -O "$raw" "$url" || {
			rm -f "$raw"
			return 1
		}
	else
		log "adblock: need curl or wget"
		return 1
	fi
	# HTML error?
	if head -c 64 "$raw" | grep -qiE '<!doctype|<html'; then
		log "adblock: fetch returned HTML"
		rm -f "$raw"
		return 1
	fi
	norm=$RVPN_RUN/adblock.norm.$$
	adblock_normalize_stream <"$raw" | sort -u >"$norm"
	rm -f "$raw"
	n=$(wc -l <"$norm" | tr -d ' ')
	# Safety: upstream small list should be large; don't clobber good cache
	prev=0
	[ -f "$ADBLOCK_CACHE" ] && prev=$(adblock_normalize_stream <"$ADBLOCK_CACHE" | wc -l | tr -d ' ')
	if [ "${n:-0}" -lt 1000 ]; then
		if [ "${prev:-0}" -ge 1000 ]; then
			log "adblock: fetch too small ($n) — keep cache ($prev)"
			rm -f "$norm"
			return 1
		fi
		# first install / tiny seed-only ok if still useful
		if [ "${n:-0}" -lt 50 ]; then
			log "adblock: fetch unusable ($n domains)"
			rm -f "$norm"
			return 1
		fi
	fi
	mv "$norm" "$ADBLOCK_CACHE"
	chmod 644 "$ADBLOCK_CACHE" 2>/dev/null || true
	date +%s 2>/dev/null >"$RVPN_RUN/adblock.last_fetch" || true
	log "adblock: cache updated ($n domains) from $url"
	echo "$n"
}

adblock_ensure_cache() {
	if [ -f "$ADBLOCK_CACHE" ] && [ -s "$ADBLOCK_CACHE" ]; then
		return 0
	fi
	adblock_fetch || {
		# offline: seed only
		[ -f "$ADBLOCK_SEED" ] || return 1
		adblock_normalize_stream <"$ADBLOCK_SEED" | sort -u >"$ADBLOCK_CACHE"
		[ -s "$ADBLOCK_CACHE" ]
	}
}

adblock_uci_hook_confdir() {
	# Prefer OpenWrt confdir /tmp/dnsmasq.d
	cur=$(uci -q get dhcp.@dnsmasq[0].confdir)
	if [ -z "$cur" ]; then
		uci set dhcp.@dnsmasq[0].confdir='/tmp/dnsmasq.d'
		uci commit dhcp
	fi
	mkdir -p /tmp/dnsmasq.d
}

adblock_remove_link() {
	rm -f "$ADBLOCK_LINK"
}

adblock_apply() {
	mkdir -p "$RVPN_RUN"
	if ! adblock_enabled; then
		adblock_remove_link
		dns_reload
		log "adblock: off"
		return 0
	fi
	adblock_ensure_cache || {
		log "adblock: no list available"
		return 1
	}
	n=$(adblock_generate_conf)
	adblock_uci_hook_confdir
	ln -sf "$ADBLOCK_CONF" "$ADBLOCK_LINK"
	dns_reload
	log "adblock: on ($n domains)"
	return 0
}

adblock_update() {
	adblock_fetch || return 1
	adblock_enabled && adblock_apply
	return 0
}

adblock_status_line() {
	en=$(uci_get adblock_enabled)
	[ -n "$en" ] || en=0
	domains=0
	updated=
	if [ -f "$ADBLOCK_META" ]; then
		domains=$(sed -n 's/^domains=//p' "$ADBLOCK_META" | head -1)
		updated=$(sed -n 's/^updated=//p' "$ADBLOCK_META" | head -1)
	fi
	active=0
	if [ "$en" = "1" ] && { [ -L "$ADBLOCK_LINK" ] || [ -f "$ADBLOCK_LINK" ]; }; then
		active=1
	fi
	echo "adblock_enabled=$en active=$active domains=${domains:-0} updated=${updated:-—}"
}

adblock_cron_tick() {
	adblock_enabled || return 0
	hours=$(uci_get adblock_update_hours)
	[ -n "$hours" ] || hours=24
	case "$hours" in ''|*[!0-9]*) hours=24 ;; esac
	[ "$hours" -ge 1 ] || hours=24
	# stamp file age
	stamp=$RVPN_RUN/adblock.last_fetch
	now=$(date +%s 2>/dev/null || echo 0)
	if [ -f "$stamp" ] && [ "$now" != 0 ]; then
		last=$(cat "$stamp" 2>/dev/null || echo 0)
		age=$((now - last))
		max=$((hours * 3600))
		[ "$age" -lt "$max" ] && return 0
	fi
	if adblock_fetch; then
		echo "$now" >"$stamp"
		adblock_apply
	fi
}
