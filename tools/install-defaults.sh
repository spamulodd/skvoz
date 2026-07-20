# Shared defaults for Skvoz install / update (sourced by install.sh).
# shellcheck shell=sh

SKVOZ_REPO=${SKVOZ_REPO:-spamulodd/skvoz}
SKVOZ_EDITION=${SKVOZ_EDITION:-standard}
SKVOZ_GH_API=${SKVOZ_GH_API:-https://api.github.com/repos/${SKVOZ_REPO}/releases/latest}

# Mirror prefixes tried when api.github.com / github.com blocked
# Final URL = prefix + original https URL (ghproxy) or jsdelivr path
skvoz_mirror_urls() {
	orig=$1
	echo "$orig"
	echo "https://ghproxy.com/${orig}"
	echo "https://mirror.ghproxy.com/${orig}"
}

skvoz_curl() {
	url=$1
	out=$2
	curl -fsSL --connect-timeout 8 --max-time 180 -L "$url" -o "$out" 2>/dev/null
}

skvoz_fetch_url_mirrors() {
	url=$1
	out=$2
	for u in $(skvoz_mirror_urls "$url"); do
		if skvoz_curl "$u" "$out" && [ -s "$out" ]; then
			echo "$u"
			return 0
		fi
	done
	return 1
}
