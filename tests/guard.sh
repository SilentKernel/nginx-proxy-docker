#!/usr/bin/env bash
# Negative test of the build guard in the Dockerfile: building on an official image older than
# MIN_NGINX_VERSION must FAIL, and so must a NGINX_VERSION that is not the binary's. Cheap: nothing
# is compiled, two small builds that stop at the guard.
#   tests/guard.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
set -a
. ./versions.env
set +a

# The official 1.30.5, one patch release below the floor (MIN_NGINX_VERSION=1.30.6), as the
# negative input. Raising the floor keeps this test valid.
OLD="nginx:1.30.5-trixie"

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

build() {   # build <base image> <NGINX_VERSION>: never tagged, never loaded
    docker buildx build --progress=plain --platform "$PLATFORM" \
        --build-arg BASE_IMAGE="$1" --build-arg NGINX_VERSION="$2" --build-arg MIN_NGINX_VERSION="$MIN_NGINX_VERSION" \
        "$ROOT" >"$log" 2>&1
}

if build "$OLD" 1.30.5; then
    echo "FAIL: the image was built on ${OLD} (nginx 1.30.5 < ${MIN_NGINX_VERSION}): the guard did not fire" >&2
    exit 1
fi
if ! grep -q "refusing to build a vulnerable image" "$log"; then
    tail -30 "$log" >&2
    echo "FAIL: the build on ${OLD} failed, but not because of the version guard" >&2
    exit 1
fi
grep -E '^#[0-9]+ [0-9.]+ nginx [0-9.]+ expected=' "$log" | tail -1
echo "ok   the guard refuses ${OLD} (floor ${MIN_NGINX_VERSION})"

# The same old image announced as the floor version: the binary check must catch the lie.
if build "$OLD" "$MIN_NGINX_VERSION"; then
    echo "FAIL: ${OLD} was built while announced as ${MIN_NGINX_VERSION}" >&2
    exit 1
fi
if ! grep -q "nginx is 1.30.5, not ${MIN_NGINX_VERSION}" "$log"; then
    tail -30 "$log" >&2
    echo "FAIL: the mislabelled build failed, but not because of the version check" >&2
    exit 1
fi
echo "ok   the guard refuses an NGINX_VERSION that is not the binary's"
