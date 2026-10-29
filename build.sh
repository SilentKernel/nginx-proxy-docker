#!/usr/bin/env bash
# Builds the nginx-proxy image (IMAGE in versions.env) for production (amd64), tests it, and pushes
# it to our registry with --push, only when its content changed.
#
#   ./build.sh                 build + test
#   ./build.sh --push          build + test + push the four tags (when the content changed)
#   ./build.sh --push --force  push even when the content is what the registry already serves
#   NGINX_BASE_TAG=1.30.6-trixie ./build.sh   build on a given official tag (rollback, reproduction)
#
# The image starts FROM the official nginx:<series>-trixie (Debian, nginx.org's signed packages),
# pulled fresh and pinned by digest, then `apt-get upgrade` for Debian fixes; upstream's /app comes
# from nginxproxy/nginx-proxy:<version>, pinned by digest. docker-gen and forego are compiled from
# their upstream release commits on our go-docker (pinned by digest, its Go version from its label)
# with go/<tool>/go.mod + go.sum. The Dockerfile refuses an nginx below MIN_NGINX_VERSION and a Go
# below MIN_GO_VERSION; --push refuses an nginx older than the moving tag serves. An official image
# lagging behind nginx.org's latest <series>.x is reported (ntfy).
#
# Content fingerprint: a restart of nginx-proxy cuts every site for a few seconds, so the server is
# only offered a new image when something in it changed. io.silent.content is the sha256 of the
# installed Debian packages (dpkg), the nginx and Go versions, the digest of upstream nginx-proxy,
# the Dockerfile, versions.env, the Go guard and the go/ module files. When the moving tag already
# serves that fingerprint, nothing is pushed (the gates still run: they are the nightly health check).
#
# Tags: <nginx>-trixie-YYYYMMDD (never overwritten, for rollbacks), <nginx>-trixie (latest build of
# that version), <series>-trixie and latest (moving, what the server pulls).
#
# Before anything is pushed, the candidate must pass tests/smoke.sh (routing through docker-gen,
# HTTP/HTTPS/HTTP2, upstream's template and the server's), tests/go-binaries.sh (docker-gen and
# forego compiled by the expected Go, with the fixed modules), tests/os-updates.sh (no Debian update
# pending) and tests/negative.sh (the gates still catch broken images); tests/scan.sh refuses a new
# fixable CRITICAL CVE. The candidate lives under a private local name until the push, and after the
# push the registry must serve exactly the tested image.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

PUSH=0 FORCE=0
for arg in "$@"; do
    case "$arg" in
        --push) PUSH=1 ;;
        --force) FORCE=1 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

set -a
# shellcheck source=versions.env
. ./versions.env
set +a

if [ "$PUSH" = 1 ] && [ -d .git ] && [ -n "$(git status --porcelain)" ]; then
    echo "refusing to push from a dirty working tree: the pushed image would match no commit" >&2
    exit 1
fi
SOURCE_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo none)"

echo "==> resolving the latest nginx ${NGINX_SERIES}.x on nginx.org"
resolved="$("$ROOT/scripts/resolve-versions.sh")"
eval "$resolved"
echo "    nginx.org: ${NGINX_LATEST}"

# The official image: its digest (what we build FROM) and the nginx version it ships.
BASE_TAG="nginx:${NGINX_BASE_TAG:-${NGINX_SERIES}-trixie}"
echo "==> reading ${BASE_TAG}"
read -r BASE_DIGEST NGINX_VERSION < <(docker buildx imagetools inspect "$BASE_TAG" --format '{{json .}}' | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
image = d.get("image") or {}
if "config" not in image:   # multi-platform index: one entry per platform
    image = image[sys.argv[1]]
env = dict(e.split("=", 1) for e in image.get("config", {}).get("Env") or [])
print(d["manifest"]["digest"], env.get("NGINX_VERSION", "-"))
' "$PLATFORM") || { echo "cannot read ${BASE_TAG}" >&2; exit 1; }
[[ "$NGINX_VERSION" =~ ^${NGINX_SERIES//./\\.}\.[0-9]+$ ]] \
    || { echo "${BASE_TAG} ships nginx '${NGINX_VERSION}', not a ${NGINX_SERIES}.x release" >&2; exit 1; }
BASE_IMAGE="nginx@${BASE_DIGEST}"
echo "    ${BASE_TAG} = ${BASE_IMAGE}: nginx ${NGINX_VERSION}"
export NGINX_VERSION BASE_IMAGE

# go-docker, where docker-gen and forego are compiled: its digest and the Go it ships (its label).
GO_TAG="${GO_BASE_IMAGE}:${GO_BASE_TAG}"
echo "==> reading ${GO_TAG}"
read -r GO_DIGEST GO_VERSION < <(docker buildx imagetools inspect "$GO_TAG" --format '{{json .}}' | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
image = d.get("image") or {}
if "config" not in image:   # multi-platform index: one entry per platform
    image = image[sys.argv[1]]
labels = image.get("config", {}).get("Labels") or {}
print(d["manifest"]["digest"], labels.get("dev.go-docker.go-version") or "-")
' "$PLATFORM") || { echo "cannot read ${GO_TAG} (not logged in to the registry?)" >&2; exit 1; }
[[ "$GO_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "${GO_TAG} announces Go '${GO_VERSION}', not a release" >&2; exit 1; }
GO_IMAGE="${GO_BASE_IMAGE}@${GO_DIGEST}"
export GO_IMAGE GO_VERSION
echo "    ${GO_TAG} = ${GO_IMAGE}: Go ${GO_VERSION}"
echo "    docker-gen ${DOCKER_GEN_VERSION} (${DOCKER_GEN_COMMIT:0:12}), forego ${FOREGO_VERSION} (${FOREGO_COMMIT:0:12}): compiled here"

# Upstream nginx-proxy (its /app), pinned by the digest its tag serves tonight.
pin() {   # <image:tag> -> <image>@<digest>
    local digest
    digest="$(docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' | python3 -I "$ROOT/scripts/served-ids.py" --digest)" \
        || { echo "cannot read $1" >&2; return 1; }
    echo "${1%:*}@${digest}"
}
UPSTREAM_IMAGE="$(pin "nginxproxy/nginx-proxy:${NGINX_PROXY_VERSION}")"
echo "    nginx-proxy ${NGINX_PROXY_VERSION} (/app): ${UPSTREAM_IMAGE}"

TAG_VERSION="${IMAGE}:${NGINX_VERSION}-trixie"
DATE="$(date -u +%Y%m%d)"
TAG_DATED="${TAG_VERSION}-${DATE}"
TAG_MOVING="${IMAGE}:${NGINX_SERIES}-trixie"
TAG_LATEST="${IMAGE}:latest"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
STAMP="$(date -u +%Y%m%d%H%M%S)-$$"
BUILT="nginx-proxy-built:${STAMP}"
CANDIDATE="nginx-proxy-candidate:${STAMP}"
trap 'docker image rm "$CANDIDATE" "$BUILT" >/dev/null 2>&1 || true' EXIT

# What the moving tag serves today: "<nginx> <content> <manifest digest>" from its labels, or "- - -"
# if it was never pushed.
published_info() {
    local out
    if ! out="$(docker buildx imagetools inspect "$TAG_MOVING" --format '{{json .}}' 2>&1)"; then
        case "$out" in
            *"not found"*|*"NOT_FOUND"*|*"MANIFEST_UNKNOWN"*) echo "- - -"; return 0 ;;
            *) echo "cannot read ${TAG_MOVING}: ${out}" >&2; return 1 ;;
        esac
    fi
    python3 -I -c '
import json, sys
d = json.loads(sys.argv[1])
image = d.get("image") or {}
if "config" not in image:   # multi-platform index: one entry per platform
    image = image.get(sys.argv[2]) or next(iter(image.values()))
labels = image.get("config", {}).get("Labels") or {}
print(labels.get("dev.nginx-proxy.nginx-version") or "-", labels.get("io.silent.content") or "-",
      d.get("manifest", {}).get("digest") or "-")
' "$out" "$PLATFORM"
}

PUBLISHED_NGINX="" PUBLISHED_CONTENT="" PUBLISHED_DIGEST=""
if read -r PUBLISHED_NGINX PUBLISHED_CONTENT PUBLISHED_DIGEST < <(published_info); then
    [ "$PUBLISHED_NGINX" = - ] && PUBLISHED_NGINX=""
    [ "$PUBLISHED_CONTENT" = - ] && PUBLISHED_CONTENT=""
    [ "$PUBLISHED_DIGEST" = - ] && PUBLISHED_DIGEST=""
    echo "==> ${TAG_MOVING} serves nginx ${PUBLISHED_NGINX:-none}"
elif [ "$PUSH" = 1 ]; then
    echo "cannot read the published version" >&2
    exit 1
else
    echo "==> cannot read ${TAG_MOVING} (not logged in?): no comparison with the published image"
fi
if [ "$PUSH" = 1 ]; then
    "$ROOT/scripts/version-compare.sh" "$PUBLISHED_NGINX" "$NGINX_VERSION" \
        || { echo "refusing to push nginx ${NGINX_VERSION}: ${TAG_MOVING} already serves ${PUBLISHED_NGINX}" >&2; exit 1; }
fi

if ! "$ROOT/scripts/version-compare.sh" "$NGINX_LATEST" "$NGINX_VERSION"; then
    echo "==> WARNING: ${BASE_TAG} ships nginx ${NGINX_VERSION}, nginx.org has ${NGINX_LATEST}"
    "$ROOT/scripts/notify.sh" high "warning,hourglass" \
        "nginx-proxy-docker: official image lags (nginx ${NGINX_VERSION} < ${NGINX_LATEST})" \
        "${BASE_TAG} still ships nginx ${NGINX_VERSION}; nginx.org released ${NGINX_LATEST}. Built anyway (Debian fixes). If ${NGINX_LATEST} is a security release, raise MIN_NGINX_VERSION to stop publishing older builds."
fi

echo "==> building on ${BASE_IMAGE} (nginx ${NGINX_VERSION}, floor ${MIN_NGINX_VERSION}), ${PLATFORM}"
# --pull refreshes the bases; --no-cache so `apt-get upgrade` really fetches tonight's Debian fixes;
# --load puts the result in the local engine for the fingerprint and the tests.
docker buildx build --pull --no-cache --load \
    --platform "$PLATFORM" \
    --build-arg BASE_IMAGE="$BASE_IMAGE" \
    --build-arg GO_BASE_IMAGE="$GO_IMAGE" \
    --build-arg GO_VERSION="$GO_VERSION" \
    --build-arg MIN_GO_VERSION="$MIN_GO_VERSION" \
    --build-arg DOCKER_GEN_COMMIT="$DOCKER_GEN_COMMIT" \
    --build-arg FOREGO_COMMIT="$FOREGO_COMMIT" \
    --build-arg FOREGO_VERSION="$FOREGO_VERSION" \
    --build-arg UPSTREAM_IMAGE="$UPSTREAM_IMAGE" \
    --build-arg NGINX_VERSION="$NGINX_VERSION" \
    --build-arg MIN_NGINX_VERSION="$MIN_NGINX_VERSION" \
    --build-arg NGINX_PROXY_VERSION="$NGINX_PROXY_VERSION" \
    --build-arg DOCKER_GEN_VERSION="$DOCKER_GEN_VERSION" \
    --label org.opencontainers.image.title=nginx-proxy \
    --label "org.opencontainers.image.description=nginx-proxy ${NGINX_PROXY_VERSION} on nginx ${NGINX_VERSION} (official trixie image + apt-get upgrade)" \
    --label "org.opencontainers.image.version=${NGINX_VERSION}-trixie" \
    --label "org.opencontainers.image.revision=${SOURCE_COMMIT}" \
    --label "org.opencontainers.image.created=${BUILD_DATE}" \
    --label "org.opencontainers.image.base.name=docker.io/library/${BASE_TAG}" \
    --label "org.opencontainers.image.base.digest=${BASE_DIGEST}" \
    --label "dev.nginx-proxy.nginx-version=${NGINX_VERSION}" \
    --label "dev.nginx-proxy.upstream-version=${NGINX_PROXY_VERSION}" \
    --label "dev.nginx-proxy.go-version=${GO_VERSION}" \
    --label "dev.nginx-proxy.go-builder=${GO_IMAGE}" \
    --label "dev.nginx-proxy.docker-gen=${DOCKER_GEN_VERSION} ${DOCKER_GEN_COMMIT}" \
    --label "dev.nginx-proxy.forego=${FOREGO_VERSION} ${FOREGO_COMMIT}" \
    --label "dev.nginx-proxy.upstream=${UPSTREAM_IMAGE}" \
    -t "$BUILT" .

# The fingerprint needs the built image (its package list); a label-only build on top carries it
# (no layer added). The candidate, tested and pushed, is that labelled image.
packages="$(docker run --rm --platform "$PLATFORM" --entrypoint dpkg-query "$BUILT" -W -f '${Package} ${Version}\n')" \
    || { echo "cannot list the packages of ${BUILT}" >&2; exit 1; }
# The Go binaries are fixed by the Go version, the commits (versions.env) and our module files:
# go-docker's digest is left out, its nightly Debian rebuild does not change what it compiles.
CONTENT="$({
    printf 'nginx %s\ngo %s\n' "$NGINX_VERSION" "$GO_VERSION"
    printf 'image %s\n' "${UPSTREAM_IMAGE#*@}"
    cat Dockerfile versions.env scripts/go-guard.sh go/docker-gen/go.mod go/docker-gen/go.sum go/forego/go.mod go/forego/go.sum
    sort <<<"$packages"
} | python3 -I -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
printf 'FROM %s\nLABEL io.silent.content=%s\n' "$BUILT" "$CONTENT" \
    | docker build -q --platform "$PLATFORM" -t "$CANDIDATE" - >/dev/null

CANDIDATE_ID="$(docker image inspect -f '{{.Id}}' "$CANDIDATE")"
echo "==> candidate ${CANDIDATE} (${CANDIDATE_ID}), content ${CONTENT:0:12}"
UNCHANGED=0
if [ -n "$PUBLISHED_CONTENT" ] && [ "$PUBLISHED_CONTENT" = "$CONTENT" ]; then
    UNCHANGED=1
    echo "    same content as ${TAG_MOVING}: nothing to push unless --force (the gates still run)"
fi

echo "==> smoke test (routing, HTTPS, HTTP/2; upstream's template and the server's)"
"$ROOT/tests/smoke.sh" "$CANDIDATE"
echo "==> Go binaries (our builds: Go ${GO_VERSION}, fixed modules)"
"$ROOT/tests/go-binaries.sh" "$CANDIDATE"
echo "==> Debian updates (none may be pending)"
"$ROOT/tests/os-updates.sh" "$CANDIDATE"
echo "==> negative tests (the gates catch broken images)"
"$ROOT/tests/negative.sh" "$CANDIDATE"
echo "==> vulnerability gate (no new fixable ${GATE_SEVERITIES} against the published image)"
"$ROOT/tests/scan.sh" "$CANDIDATE" ${PUBLISHED_DIGEST:+"${IMAGE}@${PUBLISHED_DIGEST}"}

# Every identifier of the image the registry serves for <tag> (index, platform manifest, config):
# the tested image ID must be one of them, whatever image store the local engine uses.
served_ids() {
    local tag="$1" top raw out child
    # {{json .Manifest}}, never {{.Manifest.Digest}}: older buildx versions print their
    # human-readable block for any format starting with {{.Manifest (served-ids.py --digest reads both)
    top="$(docker buildx imagetools inspect "$tag" --format '{{json .Manifest}}' | python3 -I "$ROOT/scripts/served-ids.py" --digest)" || return 1
    raw="$(docker buildx imagetools inspect "$tag" --raw)" || return 1
    out="$(python3 -I "$ROOT/scripts/served-ids.py" "$top" "$raw" "$PLATFORM")" || return 1
    if [[ "$out" == need-child\ * ]]; then
        child="$(docker buildx imagetools inspect "${tag%:*}@${out#need-child }" --raw)" || return 1
        out="$(python3 -I "$ROOT/scripts/served-ids.py" "$top" "$raw" "$PLATFORM" "$child")" || return 1
    fi
    printf '%s\n' "$out"
}

# Pushes <tag> from the tested image, then checks the registry serves exactly that image.
push_tested() {
    local tag="$1" ids
    docker tag "$CANDIDATE_ID" "$tag"
    docker push "$tag"
    ids="$(served_ids "$tag")" || { echo "cannot read ${tag} back from the registry" >&2; exit 1; }
    if ! grep -qxF "$CANDIDATE_ID" <<<"$ids"; then
        echo "registry serves $(tr '\n' ' ' <<<"$ids")for ${tag}, not the tested image ${CANDIDATE_ID}" >&2
        exit 1
    fi
    echo "ok   ${tag} is the tested image (${CANDIDATE_ID})"
}

if [ "$PUSH" = 1 ] && [ "$UNCHANGED" = 1 ] && [ "$FORCE" = 0 ]; then
    echo "==> unchanged: ${TAG_MOVING} already serves this content (${CONTENT:0:12}); nothing pushed, nothing for the server to restart"
elif [ "$PUSH" = 1 ]; then
    echo "==> pushing ${TAG_DATED}, ${TAG_VERSION}, ${TAG_MOVING} and ${TAG_LATEST} (moving tags last)"
    push_tested "$TAG_DATED"
    push_tested "$TAG_VERSION"
    push_tested "$TAG_MOVING"
    push_tested "$TAG_LATEST"
    # A new version to roll out: the important channel (NTFY_TOPIC_NEWBASE), not NTFY_TOPIC.
    NTFY_TOPIC="${NTFY_TOPIC_NEWBASE:-}" "$ROOT/scripts/notify.sh" default "package,arrow_up" \
        "nginx-proxy: new image (nginx ${NGINX_VERSION})" \
        "${TAG_MOVING} moved (nginx ${PUBLISHED_NGINX:-none} -> ${NGINX_VERSION}, content ${CONTENT:0:12}). ./refresh.sh on the server pulls it and asks before restarting nginx-proxy."
else
    docker tag "$CANDIDATE_ID" "$TAG_VERSION"
    docker tag "$CANDIDATE_ID" "$TAG_MOVING"
    echo "==> not pushed (run with --push); tagged locally: ${TAG_VERSION}, ${TAG_MOVING}"
fi
