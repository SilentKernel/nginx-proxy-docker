#!/bin/sh
# Build guard of a Go binary (run in the Dockerfile's builder stages, as qrserve-docker's): the
# binary must be compiled by the Go build.sh expects (GO_VERSION, go-docker's label) and that Go
# must not be below the floor (MIN_GO_VERSION, versions.env). tests/guard.sh proves it refuses.
#   go-guard.sh <binary>
set -eu
bin="${1:?usage: go-guard.sh <binary>}"
test -n "${GO_VERSION:-}" && test -n "${MIN_GO_VERSION:-}"
actual="$(go version "$bin" | sed -n "s|^${bin}: go||p")"
echo "go ${actual} expected=${GO_VERSION} required>=${MIN_GO_VERSION} (${bin})"
[ "${actual}" = "${GO_VERSION}" ] || { echo "go is ${actual}, not ${GO_VERSION}" >&2; exit 1; }
lowest="$(printf '%s\n%s\n' "${actual}" "${MIN_GO_VERSION}" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)"
if [ "${lowest}" != "${MIN_GO_VERSION}" ]; then
    echo "go ${actual} is older than ${MIN_GO_VERSION}: refusing to build a vulnerable image" >&2
    exit 1
fi
