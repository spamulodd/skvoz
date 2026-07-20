# Rank + keyword-skip for subscription TSV (one pass).
# Fields: tag type server port uuid password sni pbk sid flow fp network path host method
# ENV: PREFER (comma tokens), SKIP (comma keywords), MAX (int)
BEGIN {
	FS = "\t"
	OFS = "\t"
	prefer = ENVIRON["PREFER"]
	if (prefer == "") prefer = "vless-reality,hysteria2,trojan,vless-ws,vless-grpc,vless,ss"
	skip = ENVIRON["SKIP"]
	if (skip == "") skip = "expire,剩余,流量,官网,套餐"
	max = ENVIRON["MAX"] + 0
	if (max < 1) max = 24
	npref = split(prefer, pref, ",")
	nsk = split(skip, sk, ",")
	for (i = 1; i <= nsk; i++) {
		gsub(/^[[:space:]]+|[[:space:]]+$/, "", sk[i])
		sk[i] = tolower(sk[i])
	}
}
function token_of(type, network, pbk,   t) {
	if (type == "hysteria2" || type == "hy2") return "hysteria2"
	if (type == "trojan") return "trojan"
	if (type == "ss" || type == "shadowsocks") return "ss"
	if (type == "vless") {
		if (pbk != "") return "vless-reality"
		if (network == "ws") return "vless-ws"
		if (network == "grpc") return "vless-grpc"
		return "vless"
	}
	return "other"
}
function rank_of(tok,   i) {
	for (i = 1; i <= npref; i++) {
		gsub(/^[[:space:]]+|[[:space:]]+$/, "", pref[i])
		if (pref[i] == tok) return i
	}
	return 99
}
function skipped(tag,   tl, i) {
	tl = tolower(tag)
	for (i = 1; i <= nsk; i++) {
		if (sk[i] != "" && index(tl, sk[i]) > 0) return 1
	}
	return 0
}
{
	tag = $1
	if (tag == "") next
	if (skipped(tag)) next
	type = $2; server = $3; port = $4; uuid = $5; password = $6
	sni = $7; pbk = $8; sid = $9; flow = $10; fp = $11
	network = $12; path = $13; host = $14; method = $15
	r = rank_of(token_of(type, network, pbk))
	n++
	out[n] = sprintf("%02d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s", \
		r, tag, type, server, port, uuid, password, sni, pbk, sid, flow, fp, network, path, host, method)
	key[n] = sprintf("%02d\t%s\t%s", r, type, server)
}
END {
	# insertion sort by key (small max≈hundreds)
	for (i = 2; i <= n; i++) {
		t = out[i]; k = key[i]; j = i - 1
		while (j >= 1 && key[j] > k) {
			out[j + 1] = out[j]; key[j + 1] = key[j]; j--
		}
		out[j + 1] = t; key[j + 1] = k
	}
	lim = (n < max) ? n : max
	for (i = 1; i <= lim; i++) {
		# drop rank column
		sub(/^[^\t]+\t/, "", out[i])
		print out[i]
	}
}
