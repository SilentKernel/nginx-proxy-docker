#!/usr/bin/env bash
# Negative tests of the build guards in the Dockerfile:
#   nginx: building on an official image older than MIN_NGINX_VERSION must FAIL, and so must an
#          NGINX_VERSION that is not the binary's;
#   Go:    compiling docker-gen/forego on a Go older than MIN_GO_VERSION must FAIL, and so must a
#          GO_VERSION that is not the binary's (on the official golang image and on our go-docker).
# Needs the Internet (Docker Hub, GitHub, proxy.golang.org) and a login to our registry (go-docker).
#   tests/guard.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
set -a
. ./versions.env
set +a

# One patch release below each floor, as the negative inputs. Raising a floor keeps them valid.
OLD="nginx:1.30.5-trixie"
OLD_GO="1.27.2"
OLD_GO_IMAGE="golang:${OLD_GO}-${GO_BASE_TAG#*-}"
GO_TAG="${GO_BASE_IMAGE}:${GO_BASE_TAG}"
# The Go go-docker really ships (its label): the Go stages must pass while the nginx guard is tested.
GO_NOW="$(docker buildx imagetools inspect "$GO_TAG" --format '{{json .}}' | python3 -I -c '
import json, sys
d = json.load(sys.stdin); image = d.get("image") or {}
if "config" not in image: image = image[sys.argv[1]]
print((image.get("config", {}).get("Labels") or {}).get("dev.go-docker.go-version", ""))' "$PLATFORM")" \
    || { echo "FAIL: cannot read ${GO_TAG} (not logged in to the registry?)" >&2; exit 1; }

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

# build [--target stage] [NAME=value...]: the Dockerfile with valid arguments, overridden by the
# given ones; never tagged, never loaded
build() {
    local target=() args=(
        BASE_IMAGE="nginx:${NGINX_SERIES}-trixie" NGINX_VERSION="$MIN_NGINX_VERSION" MIN_NGINX_VERSION="$MIN_NGINX_VERSION"
        GO_BASE_IMAGE="$GO_TAG" GO_VERSION="$GO_NOW" MIN_GO_VERSION="$MIN_GO_VERSION"
        DOCKER_GEN_COMMIT="$DOCKER_GEN_COMMIT" DOCKER_GEN_VERSION="$DOCKER_GEN_VERSION"
        FOREGO_COMMIT="$FOREGO_COMMIT" FOREGO_VERSION="$FOREGO_VERSION" NGINX_PROXY_VERSION="$NGINX_PROXY_VERSION")
    if [ "${1:-}" = --target ]; then target=(--target "$2"); shift 2; fi
    args+=("$@")
    local flags=() a
    for a in "${args[@]}"; do flags+=(--build-arg "$a"); done
    docker buildx build --progress=plain --platform "$PLATFORM" ${target[@]+"${target[@]}"} "${flags[@]}" "$ROOT" >"$log" 2>&1
}
refused() {   # refused <what> <expected log line part>: the last build failed, for that reason
    if ! grep -qF "$2" "$log"; then
        tail -30 "$log" >&2
        echo "FAIL: $1 failed, but not because of the guard ($2)" >&2
        exit 1
    fi
}

# --- nginx
if build BASE_IMAGE="$OLD" NGINX_VERSION=1.30.5; then
    echo "FAIL: the image was built on ${OLD} (nginx 1.30.5 < ${MIN_NGINX_VERSION}): the guard did not fire" >&2
    exit 1
fi
refused "the build on ${OLD}" "refusing to build a vulnerable image"
grep -E '^#[0-9]+ [0-9.]+ nginx [0-9.]+ expected=' "$log" | tail -1
echo "ok   the guard refuses ${OLD} (floor ${MIN_NGINX_VERSION})"

if build BASE_IMAGE="$OLD" NGINX_VERSION="$MIN_NGINX_VERSION"; then
    echo "FAIL: ${OLD} was built while announced as ${MIN_NGINX_VERSION}" >&2
    exit 1
fi
refused "the mislabelled build" "nginx is 1.30.5, not ${MIN_NGINX_VERSION}"
echo "ok   the guard refuses an NGINX_VERSION that is not the binary's"

# --- Go (forego's stage: the same scripts/go-guard.sh runs in docker-gen's)
if build --target build-forego GO_BASE_IMAGE="$OLD_GO_IMAGE" GO_VERSION="$OLD_GO"; then
    echo "FAIL: forego was compiled on ${OLD_GO_IMAGE} (go ${OLD_GO} < ${MIN_GO_VERSION}): the guard did not fire" >&2
    exit 1
fi
refused "the build on ${OLD_GO_IMAGE}" "go ${OLD_GO} is older than ${MIN_GO_VERSION}: refusing to build a vulnerable image"
grep -E '^#[0-9]+ [0-9.]+ go [0-9.]+ expected=' "$log" | tail -1
echo "ok   the Go guard refuses ${OLD_GO_IMAGE} (floor ${MIN_GO_VERSION})"

if build --target build-forego GO_BASE_IMAGE="$OLD_GO_IMAGE" GO_VERSION="$MIN_GO_VERSION"; then
    echo "FAIL: ${OLD_GO_IMAGE} was used while announced as ${MIN_GO_VERSION}" >&2
    exit 1
fi
refused "the mislabelled Go build" "go is ${OLD_GO}, not ${MIN_GO_VERSION}"
echo "ok   the Go guard refuses a GO_VERSION that is not the binary's"

if build --target build-forego GO_VERSION="${GO_BASE_TAG%%-*}.999"; then
    echo "FAIL: ${GO_TAG} was used while announced as ${GO_BASE_TAG%%-*}.999" >&2
    exit 1
fi
refused "the build on go-docker" "go is ${GO_NOW}, not ${GO_BASE_TAG%%-*}.999"
echo "ok   the Go guard refuses go-docker announced as a Go it does not ship"
