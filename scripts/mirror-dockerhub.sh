#!/usr/bin/env bash
# Backup of the published image on Docker Hub (or any registry): copies what our moving tag serves,
# under its four tags, byte for byte (same manifest digest), and checks the destination serves it.
#   scripts/mirror-dockerhub.sh <source image> <destination image>
#   scripts/mirror-dockerhub.sh "$IMAGE" "$DOCKERHUB_IMAGE"        (CI: job mirror:dockerhub)
#
# Copies registry to registry (docker buildx imagetools create --prefer-index=false: a carbon copy,
# the blobs and the manifest bytes are kept), so it needs no local image and runs on any runner.
# Self-healing: each tag is compared by digest and only a missing or different one is copied, so a
# night where Docker Hub was unreachable is repaired by the next pipeline, even an "unchanged" one.
# Tags, in build.sh's push order (moving tags last): <nginx>-trixie-YYYYMMDD, <nginx>-trixie,
# <series>-trixie, latest (scripts/mirror-tags.py derives them from the image's labels).
#
# Needs NGINX_SERIES and PLATFORM (versions.env), push access to the destination (docker login) and
# pull access to the source. On failure: ntfy alert (scripts/notify.sh), exit 1.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ $# = 2 ] || { echo "usage: $0 <source image> <destination image>" >&2; exit 2; }
SRC="$1" DST="$2"
: "${NGINX_SERIES:?NGINX_SERIES is not set (source versions.env)}"
: "${PLATFORM:?PLATFORM is not set (source versions.env)}"
[ "$SRC" != "$DST" ] || { echo "source and destination are the same image: ${SRC}" >&2; exit 2; }

STEP="reading ${SRC}:${NGINX_SERIES}-trixie"
on_exit() {
    local status=$?
    [ "$status" = 0 ] && return 0
    echo "FAIL mirror to ${DST}: ${STEP}" >&2
    "$ROOT/scripts/notify.sh" high "warning,floppy_disk" \
        "nginx-proxy-docker: Docker Hub backup FAILED" \
        "Copy of ${SRC} to ${DST} failed while ${STEP}. Production is not affected (our registry is the source); the next pipeline retries the missing tags."
    exit "$status"
}
trap on_exit EXIT

# Top-level digest a registry serves for <ref>, "-" when the tag does not exist.
digest_of() {
    local out
    if ! out="$(docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' 2>&1)"; then
        case "$out" in
            *"not found"*|*"NOT_FOUND"*|*"MANIFEST_UNKNOWN"*) echo -; return 0 ;;
            *) echo "cannot read $1: ${out}" >&2; return 1 ;;
        esac
    fi
    python3 -I "$ROOT/scripts/served-ids.py" --digest <<<"$out"
}

inspect="$(docker buildx imagetools inspect "${SRC}:${NGINX_SERIES}-trixie" --format '{{json .}}')"
lines="$(python3 -I "$ROOT/scripts/mirror-tags.py" "$NGINX_SERIES" "$PLATFORM" <<<"$inspect")"
DIGEST="$(head -n1 <<<"$lines")"
TAGS=()
while read -r tag; do TAGS+=("$tag"); done < <(tail -n +2 <<<"$lines")
echo "==> ${SRC}:${NGINX_SERIES}-trixie = ${DIGEST}; mirroring ${TAGS[*]} to ${DST}"

copied=0
for tag in "${TAGS[@]}"; do
    STEP="checking ${SRC}:${tag}"
    src_digest="$(digest_of "${SRC}:${tag}")"
    if [ "$src_digest" != "$DIGEST" ]; then
        echo "${SRC}:${tag} serves ${src_digest}, not the moving tag's image ${DIGEST}" >&2
        exit 1
    fi
    STEP="reading ${DST}:${tag}"
    dst_digest="$(digest_of "${DST}:${tag}")"
    if [ "$dst_digest" = "$DIGEST" ]; then
        echo "ok   ${DST}:${tag} already mirrored (${DIGEST})"
        continue
    fi
    STEP="copying ${tag}"
    echo "==> copying ${tag} (destination had ${dst_digest})"
    docker buildx imagetools create --prefer-index=false --progress plain -t "${DST}:${tag}" "${SRC}@${DIGEST}"
    STEP="reading ${DST}:${tag} back"
    dst_digest="$(digest_of "${DST}:${tag}")"
    if [ "$dst_digest" != "$DIGEST" ]; then
        echo "${DST}:${tag} serves ${dst_digest} after the copy, not ${DIGEST}" >&2
        exit 1
    fi
    echo "ok   ${DST}:${tag} = ${DIGEST} (copied)"
    copied=$((copied + 1))
done
echo "==> ${DST}: ${#TAGS[@]} tags serve ${DIGEST} (${copied} copied)"
