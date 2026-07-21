#!/bin/sh
# Flowseal strategy catalog → nfqws args for Skvoz.
# Strategies live in /usr/share/rvpn/zapret-strategies/*.strategy
[ "${RVPN_ZAPRET_STRAT_SOURCED:-0}" = "1" ] && return 0
RVPN_ZAPRET_STRAT_SOURCED=1

. /usr/lib/rvpn/common.sh

ZAP_STRAT_DIR=/usr/share/rvpn/zapret-strategies
ZAP_FAKE_DIR=/usr/share/rvpn/fake
ZAP_STRAT_ACTIVE=$RVPN_RUN/zapret.strategy
ZAP_STRAT_ARGS=$RVPN_RUN/zapret.args

zapret_strat_default() {
	echo general_alt11
}

zapret_strat_id() {
	id=$(uci_get zapret_strategy)
	[ -n "$id" ] || id=$(zapret_strat_default)
	# sanitize
	echo "$id" | tr -cd 'A-Za-z0-9_-'
}

zapret_strat_list() {
	if [ -f "$ZAP_STRAT_DIR/INDEX" ]; then
		cat "$ZAP_STRAT_DIR/INDEX"
		return 0
	fi
	for f in "$ZAP_STRAT_DIR"/*.strategy; do
		[ -f "$f" ] || continue
		basename "$f" .strategy
	done
}

zapret_strat_file() {
	id=$1
	[ -n "$id" ] || id=$(zapret_strat_id)
	f="$ZAP_STRAT_DIR/${id}.strategy"
	[ -f "$f" ] || return 1
	echo "$f"
}

# Merged hostlist: dpi shipped + user + Flowseal list-general (+ exclude applied via grep -v).
# Written under RVPN_NFQ_RUN so nobody (nfqws) can read it after priv-drop.
zapret_hostlist_build() {
	out=$1
	[ -n "$out" ] || out=$RVPN_NFQ_RUN/dpi.merged
	mkdir -p "$RVPN_NFQ_RUN" 2>/dev/null || true
	chmod 755 "$RVPN_NFQ_RUN" 2>/dev/null || true
	tmp=$RVPN_NFQ_RUN/dpi.build.$$
	: >"$tmp"
	list_domains "$RVPN_RULES/dpi.txt" >>"$tmp" 2>/dev/null || true
	list_domains "$RVPN_DPI_USER" >>"$tmp" 2>/dev/null || true
	fl=$ZAP_STRAT_DIR/lists/list-general.txt
	[ -f "$fl" ] && list_domains "$fl" >>"$tmp"
	# exclude
	ex=$ZAP_STRAT_DIR/lists/list-exclude.txt
	if [ -f "$ex" ] && [ -s "$tmp" ]; then
		list_domains "$ex" 2>/dev/null | awk 'NF{print tolower($0)}' >"$tmp.ex"
		awk 'NF{print tolower($0)}' "$tmp" | grep -vxFf "$tmp.ex" >"$tmp.f" || cp "$tmp" "$tmp.f"
		mv "$tmp.f" "$tmp"
		rm -f "$tmp.ex"
	fi
	awk 'NF && !seen[$0]++' "$tmp" >"$out"
	rm -f "$tmp"
	chmod 644 "$out" 2>/dev/null || true
	# keep a copy for UI/debug under private run dir
	cp -f "$out" "$RVPN_RUN/dpi.merged" 2>/dev/null || true
	echo "$out"
}

# Resolve HOSTLIST / FAKE: tokens in strategy → real paths. Writes arg file (one arg/line).
zapret_strat_resolve_args() {
	id=$1
	hl=$2
	[ -n "$hl" ] || hl=$(zapret_hostlist_build)
	sf=$(zapret_strat_file "$id") || {
		log "ERROR: strategy not found: $id"
		return 1
	}
	fake_dir=$ZAP_FAKE_DIR
	[ -d "$fake_dir" ] || fake_dir=/opt/rvpn/fake

	: >"$ZAP_STRAT_ARGS"
	while IFS= read -r line || [ -n "$line" ]; do
		line=$(printf '%s' "$line" | tr -d '\r')
		case "$line" in
		''|\#*) continue ;;
		esac
		# stop at reference section
		case "$line" in
		\#\ ---*) break ;;
		esac
		arg=$line
		case "$arg" in
		--hostlist=HOSTLIST|--hostlist=\"HOSTLIST\")
			arg="--hostlist=$hl"
			;;
		*=FAKE:*)
			key=${arg%%=FAKE:*}
			bin=${arg#*=FAKE:}
			bin=$(printf '%s' "$bin" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
			path="$fake_dir/$bin"
			if [ ! -f "$path" ]; then
				log "WARN: fake missing $bin — skip arg"
				continue
			fi
			arg="${key}=${path}"
			;;
		*=LIST:*)
			# remaining LIST: refs unused in primary profile
			continue
			;;
		--filter-tcp=*)
			# nft already queues 80,443; keep filter for nfqws host matching
			;;
		esac
		printf '%s\n' "$arg" >>"$ZAP_STRAT_ARGS"
	done <"$sf"

	# Always force our qnum/hostlist if strategy omitted hostlist
	if ! grep -q '^--hostlist=' "$ZAP_STRAT_ARGS" 2>/dev/null; then
		printf '%s\n' "--hostlist=$hl" >>"$ZAP_STRAT_ARGS"
	fi
	echo "$id" >"$ZAP_STRAT_ACTIVE"
	return 0
}

zapret_strat_set() {
	id=$1
	[ -n "$id" ] || return 1
	zapret_strat_file "$id" >/dev/null || return 1
	uci set rvpn.main.zapret_strategy="$id"
	uci commit rvpn
	log "zapret strategy → $id"
	echo "$id"
}

zapret_strat_json() {
	cur=$(zapret_strat_id)
	echo -n '{"ok":1,"current":"'
	printf '%s' "$(json_escape "$cur")"
	echo -n '","strategies":['
	sep=
	for id in $(zapret_strat_list); do
		printf '%s"%s"' "$sep" "$(json_escape "$id")"
		sep=,
	done
	echo -n '],"pending_sync":'
	if [ -f "$RVPN_RUN/zapret_sync.pending" ]; then
		echo -n '1'
	else
		echo -n '0'
	fi
	echo -n ',"last_test":'
	if [ -f "$RVPN_RUN/zapret_test.json" ]; then
		# already one-line json object
		tr -d '\n\r' <"$RVPN_RUN/zapret_test.json"
	else
		echo -n 'null'
	fi
	echo '}'
}
