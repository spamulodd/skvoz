#!/bin/sh
# zapret / nfqws — DPI bypass for dpi.txt (YouTube video/player, trackers)

. /usr/lib/rvpn/common.sh

NFQWS_BIN=/opt/rvpn/nfqws
NFQWS_ALT=/usr/bin/nfqws
ZAP_DIR=/opt/rvpn
ZAP_PID=$RVPN_RUN/nfqws.pid

zapret_bin() {
	if [ -x "$NFQWS_BIN" ]; then
		echo "$NFQWS_BIN"
	elif [ -x "$NFQWS_ALT" ]; then
		echo "$NFQWS_ALT"
	elif command -v nfqws >/dev/null 2>&1; then
		command -v nfqws
	else
		echo ""
	fi
}

zapret_ensure_bin() {
	b=$(zapret_bin)
	[ -n "$b" ] && [ -x "$b" ] && return 0
	mkdir -p "$ZAP_DIR"
	for cand in "$ZAP_DIR/nfqws" /usr/share/rvpn/bin/nfqws /tmp/rvpn-nfqws; do
		if [ -f "$cand" ]; then
			cp -f "$cand" "$NFQWS_BIN"
			chmod +x "$NFQWS_BIN"
			[ -x "$NFQWS_BIN" ] && return 0
		fi
	done
	log "WARN: nfqws binary missing — place at $NFQWS_BIN"
	return 1
}

zapret_start() {
	zap=$(uci_get zapret_enabled)
	[ "$zap" = "1" ] || return 0

	zapret_ensure_bin || return 1
	b=$(zapret_bin)
	qnum=$(uci_get zapret_qnum)
	[ -n "$qnum" ] || qnum=200
	hl="$RVPN_RULES/dpi.txt"

	killall nfqws 2>/dev/null || true
	sleep 1

	# Stronger TLS fake helps YT image hosts under DPI
	fake_tls=""
	[ -f /opt/zapret/files/fake/tls_clienthello_www_google_com.bin ] && \
		fake_tls="--dpi-desync-fake-tls=/opt/zapret/files/fake/tls_clienthello_www_google_com.bin"
	[ -z "$fake_tls" ] && [ -f /usr/share/rvpn/fake/tls_clienthello_www_google_com.bin ] && \
		fake_tls="--dpi-desync-fake-tls=/usr/share/rvpn/fake/tls_clienthello_www_google_com.bin"

	# shellcheck disable=SC2086
	"$b" \
		--daemon \
		--pidfile="$ZAP_PID" \
		--qnum="$qnum" \
		--filter-tcp=80,443 \
		--hostlist="$hl" \
		--dpi-desync=fake,multisplit \
		--dpi-desync-split-pos=1,midsld \
		--dpi-desync-fooling=md5sig \
		--dpi-desync-repeats=8 \
		$fake_tls \
		>/tmp/rvpn/nfqws.log 2>&1

	sleep 2
	if pgrep -f '/opt/rvpn/nfqws' >/dev/null 2>&1 || pgrep -x nfqws >/dev/null 2>&1; then
		log "nfqws started qnum=$qnum"
		return 0
	fi
	if [ -f "$ZAP_PID" ] && kill -0 "$(cat "$ZAP_PID")" 2>/dev/null; then
		log "nfqws started qnum=$qnum (pidfile)"
		return 0
	fi
	log "ERROR: nfqws failed"
	tail -30 /tmp/rvpn/nfqws.log >>"$RVPN_LOG" 2>/dev/null
	return 1
}

zapret_stop() {
	[ -f "$ZAP_PID" ] && kill "$(cat "$ZAP_PID")" 2>/dev/null || true
	killall nfqws 2>/dev/null || true
	rm -f "$ZAP_PID"
	log "nfqws stopped"
}
