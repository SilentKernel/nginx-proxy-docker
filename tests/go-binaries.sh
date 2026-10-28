#!/usr/bin/env bash
# Gate: docker-gen and forego in <image> are our builds: compiled by the expected Go (not below the
# floor), with every module of DOCKER_GEN_GO_GET / FOREGO_GO_GET at least at its fixed version.
# Read from the binaries' own build information (`go version -m`, in go-docker: the image itself has
# no Go). Needs the registry login (go-docker).
#   tests/go-binaries.sh <image>
set -euo pipefail

TARGET="${1:?usage: tests/go-binaries.sh <image>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
set -a
. "$ROOT/versions.env"
set +a
# What build.sh compiled with (exported), else the image's label, else go-docker's moving tag.
GO_IMAGE="${GO_IMAGE:-${GO_BASE_IMAGE}:${GO_BASE_TAG}}"
GO_VERSION="${GO_VERSION:-$(docker image inspect -f '{{ index .Config.Labels "dev.nginx-proxy.go-version" }}' "$TARGET")}"
[ -n "$GO_VERSION" ] || { echo "FAIL: no expected Go version (env or label)" >&2; exit 1; }

cid="$(docker create --platform "$PLATFORM" "$TARGET")"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
FAILED=0

check() {   # <binary name> <path in the image> <go get list>
    local name="$1" path="$2" bumps="$3" info
    # the binary leaves the image as a tar on stdout, into go-docker: no bind mount
    info="$(docker cp "${cid}:${path}" - | docker run --rm -i --platform "$PLATFORM" --entrypoint sh "$GO_IMAGE" \
        -c 'tar -x -C /tmp && go version -m "/tmp/$1"' _ "$name")" \
        || { echo "FAIL ${name}: cannot read its build information" >&2; FAILED=1; return; }
    python3 -I "$ROOT/scripts/go-buildinfo.py" "$name" "$GO_VERSION" "$MIN_GO_VERSION" "$bumps" <<<"$info" || FAILED=1
}

check docker-gen /usr/local/bin/docker-gen "$DOCKER_GEN_GO_GET"
check forego /usr/local/bin/forego "$FOREGO_GO_GET"

if [ "$FAILED" = 0 ]; then echo "go binaries: our builds, on Go ${GO_VERSION}, every fixed module present"; else exit 1; fi
