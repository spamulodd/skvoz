#!/bin/sh
# zapret / nfqws — DPI bypass for dpi.txt

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

# Kill only Skvoz nfqws (pidfile and /opt/rvpn/nfqws) — never killall.
zapret_kill_ours() {
	if [ -f "$ZAP_PID" ]; then
		kill "$(cat "$ZAP_PID")" 2>/dev/null || true
		rm -f "$ZAP_PID"
	fi
	# Match only our binary path
	pids=$(pgrep -f '^/opt/rvpn/nfqws' 2>/dev/null || true)
	for p in $pids; do
		kill "$p" 2>/dev/null || true
	done
}

zapret_running() {
	if [ -f "$ZAP_PID" ] && kill -0 "$(cat "$ZAP_PID" 2>/dev/null)" 2>/dev/null; then
		return 0
	fi
	pgrep -f '^/opt/rvpn/nfqws' >/dev/null 2>&1
}

zapret_start() {
	zap=$(uci_get zapret_enabled)
	[ "$zap" = "1" ] || return 0

	zapret_ensure_bin || return 1
	b=$(zapret_bin)
	qnum=$(uci_get zapret_qnum)
	[ -n "$qnum" ] || qnum=200
	case "$qnum" in
	''|*[!0-9]*) qnum=200 ;;
	esac
	hl="$RVPN_RULES/dpi.txt"

	zapret_kill_ours
	sleep 1

	# Fake payloads — prefer ALT11 (max_ru + stun), else google clienthello.
	fake_args=""
	fake_dir=""
	for d in /usr/share/rvpn/fake /opt/zapret/files/fake /opt/rvpn/fake; do
		[ -d "$d" ] && fake_dir="$d" && break
	done
	if [ -n "$fake_dir" ]; then
		[ -f "$fake_dir/stun.bin" ] && \
			fake_args="$fake_args --dpi-desync-fake-tls=$fake_dir/stun.bin"
		if [ -f "$fake_dir/tls_clienthello_max_ru.bin" ]; then
			fake_args="$fake_args --dpi-desync-fake-tls=$fake_dir/tls_clienthello_max_ru.bin"
			fake_args="$fake_args --dpi-desync-fake-http=$fake_dir/tls_clienthello_max_ru.bin"
			fake_args="$fake_args --dpi-desync-split-seqovl-pattern=$fake_dir/tls_clienthello_max_ru.bin"
		elif [ -f "$fake_dir/tls_clienthello_www_google_com.bin" ]; then
			fake_args="$fake_args --dpi-desync-fake-tls=$fake_dir/tls_clienthello_www_google_com.bin"
			fake_args="$fake_args --dpi-desync-split-seqovl-pattern=$fake_dir/tls_clienthello_www_google_com.bin"
		fi
	fi

	# Strategy from zapret-discord-youtube «general (ALT11).bat» TCP hostlist line:
	# fake,multisplit + seqovl=664 + split-pos=1 + fooling=ts + repeats=8
	# shellcheck disable=SC2086
	"$b" \
		--daemon \
		--pidfile="$ZAP_PID" \
		--qnum="$qnum" \
		--filter-tcp=80,443 \
		--hostlist="$hl" \
		--dpi-desync=fake,multisplit \
		--dpi-desync-split-seqovl=664 \
		--dpi-desync-split-pos=1 \
		--dpi-desync-fooling=ts \
		--dpi-desync-repeats=8 \
		$fake_args \
		>/tmp/rvpn/nfqws.log 2>&1

	sleep 2
	if zapret_running; then
		log "nfqws started qnum=$qnum"
		return 0
	fi
	log "ERROR: nfqws failed"
	tail -30 /tmp/rvpn/nfqws.log >>"$RVPN_LOG" 2>/dev/null
	return 1
}

zapret_stop() {
	zapret_kill_ours
	log "nfqws stopped"
}
