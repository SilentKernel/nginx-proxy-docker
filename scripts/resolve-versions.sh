#!/usr/bin/env bash
# Prints the latest nginx ${NGINX_SERIES}.x release published on nginx.org, as a KEY=value line
# (build.sh evals it):
#   NGINX_LATEST   highest nginx-${NGINX_SERIES}.N.tar.gz linked from https://nginx.org/en/download.html
#
# build.sh compares it with the nginx of the official image: an official image lagging behind
# nginx.org is reported (ntfy), not built around.
# Input (environment): NGINX_SERIES (versions.env).
# Test hook: NGINX_DOWNLOAD_HTML_FILE replaces the network call.
# Any doubt is a failure: nothing is printed and the exit code is non-zero.
set -euo pipefail

: "${NGINX_SERIES:?NGINX_SERIES is not set}"

fail() { echo "resolve-versions: $*" >&2; exit 1; }

if [ -n "${NGINX_DOWNLOAD_HTML_FILE:-}" ]; then
    html="$(cat "$NGINX_DOWNLOAD_HTML_FILE")"
else
    html="$(curl -fsSL --retry 3 --max-time 30 https://nginx.org/en/download.html)" \
        || fail "cannot reach nginx.org"
fi

# Through stdin: the page is small today, but nothing guarantees it stays below the argv limit.
latest="$(printf '%s' "$html" | python3 -I -c '
import re, sys
series = sys.argv[1]
found = set(re.findall(r"nginx-(%s\.[0-9]+)\.tar\.gz" % re.escape(series), sys.stdin.read()))
print(max(found, key=lambda v: tuple(int(x) for x in v.split("."))) if found else "")
' "$NGINX_SERIES")" || fail "cannot parse the nginx.org download page"

[[ "$latest" =~ ^${NGINX_SERIES//./\\.}\.[0-9]+$ ]] \
    || fail "no nginx ${NGINX_SERIES}.x release on the nginx.org download page"

echo "NGINX_LATEST=${latest}"
