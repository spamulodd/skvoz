#!/bin/sh
# zapret / nfqws — DPI bypass via Flowseal strategies + dpi hostlists

. /usr/lib/rvpn/common.sh
. /usr/lib/rvpn/zapret-strat.sh

NFQWS_BIN=/opt/rvpn/nfqws
NFQWS_ALT=/usr/bin/nfqws
ZAP_DIR=/opt/rvpn
ZAP_PID=$RVPN_NFQ_RUN/nfqws.pid

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
	pids=$(pgrep -f '^/opt/rvpn/nfqws' 2>/dev/null || true)
	for p in $pids; do
		kill "$p" 2>/dev/null || true
	done
}

zapret_running() {
	if [ -f "$ZAP_PID" ] && kill -0 "$(cat "$ZAP_PID" 2>/dev/null)" 2>/dev/null; then
		return 0
	fi
	# legacy pid path (pre RVPN_NFQ_RUN)
	if [ -f "$RVPN_RUN/nfqws.pid" ] && kill -0 "$(cat "$RVPN_RUN/nfqws.pid" 2>/dev/null)" 2>/dev/null; then
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

	id=$(zapret_strat_id)
	hl=$(zapret_hostlist_build)
	zapret_strat_resolve_args "$id" "$hl" || {
		log "ERROR: cannot resolve strategy $id — fallback ALT11 inline"
		# minimal fallback matching general_alt11
		fake_dir=/usr/share/rvpn/fake
		printf '%s\n' \
			"--filter-tcp=80,443" \
			"--hostlist=$hl" \
			"--dpi-desync=fake,multisplit" \
			"--dpi-desync-split-seqovl=664" \
			"--dpi-desync-split-pos=1" \
			"--dpi-desync-fooling=ts" \
			"--dpi-desync-repeats=8" \
			>"$ZAP_STRAT_ARGS"
		[ -f "$fake_dir/stun.bin" ] && \
			echo "--dpi-desync-fake-tls=$fake_dir/stun.bin" >>"$ZAP_STRAT_ARGS"
		[ -f "$fake_dir/tls_clienthello_max_ru.bin" ] && {
			echo "--dpi-desync-fake-tls=$fake_dir/tls_clienthello_max_ru.bin" >>"$ZAP_STRAT_ARGS"
			echo "--dpi-desync-fake-http=$fake_dir/tls_clienthello_max_ru.bin" >>"$ZAP_STRAT_ARGS"
			echo "--dpi-desync-split-seqovl-pattern=$fake_dir/tls_clienthello_max_ru.bin" >>"$ZAP_STRAT_ARGS"
		}
	}

	zapret_kill_ours
	sleep 1

	mkdir -p "$RVPN_NFQ_RUN" 2>/dev/null || true
	chmod 755 "$RVPN_NFQ_RUN" 2>/dev/null || true
	# Stay root: nobody cannot read RVPN_RUN(700) or write pid under /var/run
	set -- --daemon --pidfile="$ZAP_PID" --qnum="$qnum" --uid=0
	while IFS= read -r a || [ -n "$a" ]; do
		[ -n "$a" ] || continue
		set -- "$@" "$a"
	done <"$ZAP_STRAT_ARGS"

	"$b" "$@" >/tmp/rvpn/nfqws.log 2>&1

	sleep 2
	if zapret_running; then
		log "nfqws started qnum=$qnum strategy=$id"
		return 0
	fi
	log "ERROR: nfqws failed strategy=$id"
	tail -30 /tmp/rvpn/nfqws.log >>"$RVPN_LOG" 2>/dev/null
	return 1
}

zapret_stop() {
	zapret_kill_ours
	log "nfqws stopped"
}
