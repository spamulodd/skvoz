#!/usr/bin/awk -f
# Extract Clash Meta proxies[] into US-separated rows (BusyBox awk compatible).
# Delimiter: ASCII US (\037) — NOT tab (BusyBox ash IFS collapses empty tab fields).
# Columns:
# tag type server port uuid password sni pbk sid flow fp network path host method
#
# Usage: awk -f /usr/lib/rvpn/clash-parse.awk subscription.yaml

function trim(s) {
	gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
	return s
}

function unquote(s) {
	s = trim(s)
	if ((s ~ /^".*"$/) || (s ~ /^'.*'$/)) {
		return substr(s, 2, length(s) - 2)
	}
	return s
}

function slug(s,   t) {
	t = tolower(s)
	gsub(/[^a-z0-9]+/, "-", t)
	gsub(/^-+|-+$/, "", t)
	if (t == "") t = "node"
	if (length(t) > 40) t = substr(t, 1, 40)
	return t
}

function after_key(line, key,   p) {
	p = index(line, key)
	if (p == 0) return ""
	return unquote(substr(line, p + length(key)))
}

function flush(   t, n) {
	if (!in_proxy) return
	if (type == "" || type == "direct" || type == "http" || type == "socks5" || type == "selector" || type == "url-test" || type == "urltest" || type == "load-balance" || type == "fallback") {
		reset()
		return
	}
	if (server == "" || port == "") { reset(); return }
	if (server ~ /^[0-9]+$/) { reset(); return }
	if (network == "xhttp" || network == "httpupgrade") { reset(); return }

	t = slug(name)
	n = ++tagcount[t]
	if (n > 1) t = t "-" n
	gsub(/\t/, " ", t)
	gsub(/\t/, " ", type)
	gsub(/\t/, " ", server)
	gsub(/\t/, " ", port)
	gsub(/\t/, " ", uuid)
	gsub(/\t/, " ", password)
	gsub(/\t/, " ", sni)
	gsub(/\t/, " ", pbk)
	gsub(/\t/, " ", sid)
	gsub(/\t/, " ", flow)
	gsub(/\t/, " ", fp)
	gsub(/\t/, " ", network)
	gsub(/\t/, " ", path)
	gsub(/\t/, " ", host)
	gsub(/\t/, " ", method)
	# US (\037) — empty fields must survive ash `read`
	print t "\037" type "\037" server "\037" port "\037" uuid "\037" password "\037" sni "\037" pbk "\037" sid "\037" flow "\037" fp "\037" network "\037" path "\037" host "\037" method
	reset()
}

function reset() {
	in_proxy = 0
	name = type = server = port = uuid = password = sni = pbk = sid = flow = fp = network = path = host = method = ""
	in_reality = 0
	in_ws = 0
	in_grpc = 0
	in_headers = 0
}

BEGIN {
	in_proxies = 0
	reset()
}

/^proxy-groups:/ || /^rules:/ || /^rule-providers:/ {
	flush()
	in_proxies = 0
	next
}

/^proxies:/ {
	flush()
	in_proxies = 1
	next
}

!in_proxies { next }

/^[[:space:]]*-[[:space:]]+name:[[:space:]]*/ {
	flush()
	in_proxy = 1
	line = $0
	sub(/^[[:space:]]*-[[:space:]]+name:[[:space:]]*/, "", line)
	name = unquote(line)
	next
}

!in_proxy { next }

{
	raw = $0
	lead = raw
	sub(/[^ ].*/, "", lead)
	ind = length(lead)
	if (ind <= 4) {
		in_reality = 0
		in_ws = 0
		in_grpc = 0
		in_headers = 0
	}

	line = trim(raw)
	if (line == "" || line ~ /^#/) next

	if (line ~ /^reality-opts:/) { in_reality = 1; in_ws = 0; in_grpc = 0; next }
	if (line ~ /^ws-opts:/) { in_ws = 1; in_reality = 0; in_grpc = 0; next }
	if (line ~ /^grpc-opts:/) { in_grpc = 1; in_reality = 0; in_ws = 0; next }
	if (in_ws && line ~ /^headers:/) { in_headers = 1; next }

	if (in_reality) {
		if (line ~ /^public-key:/) pbk = after_key(line, "public-key:")
		else if (line ~ /^short-id:/) sid = after_key(line, "short-id:")
		next
	}
	if (in_headers) {
		if (line ~ /^[Hh]ost:/) host = after_key(line, substr(line, 1, index(line, ":")))
		# Host: value
		if (tolower(substr(line, 1, 5)) == "host:") host = unquote(substr(line, 6))
		next
	}
	if (in_ws) {
		if (line ~ /^path:/) path = after_key(line, "path:")
		next
	}
	if (in_grpc) {
		if (line ~ /^grpc-service-name:/) path = after_key(line, "grpc-service-name:")
		next
	}

	if (line ~ /^type:/) type = tolower(after_key(line, "type:"))
	else if (line ~ /^server:/) server = after_key(line, "server:")
	else if (line ~ /^port:/) port = after_key(line, "port:")
	else if (line ~ /^uuid:/) uuid = after_key(line, "uuid:")
	else if (line ~ /^password:/) password = after_key(line, "password:")
	else if (line ~ /^cipher:/) method = after_key(line, "cipher:")
	else if (line ~ /^method:/) method = after_key(line, "method:")
	else if (line ~ /^servername:/) sni = after_key(line, "servername:")
	else if (line ~ /^sni:/) sni = after_key(line, "sni:")
	else if (line ~ /^flow:/) flow = after_key(line, "flow:")
	else if (line ~ /^client-fingerprint:/) fp = after_key(line, "client-fingerprint:")
	else if (line ~ /^network:/) network = tolower(after_key(line, "network:"))
}

END { flush() }
