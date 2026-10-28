#!/usr/bin/env bash
# Tests scripts/mirror-dockerhub.sh on the real published image, with a throwaway local registry as
# the destination (no Docker Hub account needed). Needs Docker and pull access to our registry.
#   tests/mirror.sh
# Checks: first run copies the four tags byte for byte; a second run copies nothing; a tag pointing
# elsewhere is repaired alone; an unreachable destination fails (and alerts).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
set -a; . "$ROOT/versions.env"; set +a
FAILED=0
pass() { echo "ok   $*"; }
bad() { echo "FAIL $*" >&2; FAILED=1; }

REGISTRY_IMAGE="registry:3"
name="nginx-proxy-mirror-test-$$"
docker run -d --rm --name "$name" -p 127.0.0.1::5000 "$REGISTRY_IMAGE" >/dev/null
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT
port="$(docker port "$name" 5000/tcp | head -n1 | sed 's/.*://')"
for _ in $(seq 1 50); do curl -fs -o /dev/null "http://127.0.0.1:${port}/v2/" && break; sleep 0.2; done
DST="localhost:${port}/backup/nginx-proxy-docker"
echo "--- destination ${DST}"

mirror() { env -u NTFY_TOPIC "$ROOT/scripts/mirror-dockerhub.sh" "$IMAGE" "$1" 2>&1; }
digest() { docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' | python3 -I "$ROOT/scripts/served-ids.py" --digest; }

SRC_DIGEST="$(digest "${IMAGE}:${NGINX_SERIES}-trixie")"
TAGS=()
while read -r t; do TAGS+=("$t"); done < <(docker buildx imagetools inspect "${IMAGE}:${NGINX_SERIES}-trixie" \
    --format '{{json .}}' | python3 -I "$ROOT/scripts/mirror-tags.py" "$NGINX_SERIES" "$PLATFORM" | tail -n +2)
echo "    source ${IMAGE}:${NGINX_SERIES}-trixie = ${SRC_DIGEST}, tags ${TAGS[*]}"

echo "--- first run: everything copied"
if out="$(mirror "$DST")"; then
    echo "$out" | sed 's/^/    | /'
    [[ "$out" == *"4 tags serve ${SRC_DIGEST} (4 copied)"* ]] && pass "4 tags copied" || bad "first run: not 4 copied"
else
    echo "$out" | sed 's/^/    | /'; bad "first run failed"
fi
src_raw="$(docker buildx imagetools inspect --raw "${IMAGE}@${SRC_DIGEST}")"
for tag in "${TAGS[@]}"; do
    d="$(digest "${DST}:${tag}")"
    [ "$d" = "$SRC_DIGEST" ] && pass "${tag}: same digest as the source" || bad "${tag}: ${d} != ${SRC_DIGEST}"
    [ "$(docker buildx imagetools inspect --raw "${DST}:${tag}")" = "$src_raw" ] \
        && pass "${tag}: identical manifest bytes" || bad "${tag}: manifest differs"
done
# Every layer and the config really are in the destination (not only the manifest).
if python3 -I - "$src_raw" "http://127.0.0.1:${port}/v2/backup/nginx-proxy-docker/blobs" <<'PY'
import json, sys, urllib.request
m, base = json.loads(sys.argv[1]), sys.argv[2]
for b in [m["config"]] + m["layers"]:
    r = urllib.request.urlopen(urllib.request.Request(f"{base}/{b['digest']}", method="HEAD"))
    assert r.status == 200 and int(r.headers["Content-Length"]) == b["size"], b
print(f"{1 + len(m['layers'])} blobs")
PY
then pass "config and every layer present in the destination, right sizes"; else bad "blobs missing in the destination"; fi

echo "--- second run: nothing to copy"
out="$(mirror "$DST")" || bad "second run failed"
echo "$out" | sed 's/^/    | /'
[[ "$out" == *"(0 copied)"* ]] && [ "$(grep -c 'already mirrored' <<<"$out")" = 4 ] \
    && pass "idempotent: 4 already mirrored, 0 copied" || bad "second run copied something"

echo "--- a tag pointing at another image is repaired alone"
docker buildx imagetools create -t "${DST}:latest" "docker.io/library/${REGISTRY_IMAGE}" >/dev/null 2>&1
[ "$(digest "${DST}:latest")" != "$SRC_DIGEST" ] && pass "latest now points elsewhere" || bad "could not re-point latest"
out="$(mirror "$DST")" || bad "repair run failed"
echo "$out" | sed 's/^/    | /'
[[ "$out" == *"copying latest"* ]] && [[ "$out" == *"(1 copied)"* ]] && [ "$(digest "${DST}:latest")" = "$SRC_DIGEST" ] \
    && pass "only latest copied, it serves the source again" || bad "repair"

echo "--- unreachable destination: fails and alerts"
docker rm -f "$name" >/dev/null
if out="$(mirror "$DST")"; then bad "succeeded without a destination"
else
    echo "$out" | tail -n 3 | sed 's/^/    | /'
    [[ "$out" == *"FAIL mirror to ${DST}: reading ${DST}:"* ]] && pass "non-zero exit, names the step" || bad "failure message"
    [[ "$out" == *"skipped: nginx-proxy-docker: Docker Hub backup FAILED"* ]] && pass "ntfy alert sent (skipped here: no NTFY_TOPIC)" || bad "no alert"
fi

echo "--- refusals"
out="$(env -u NGINX_SERIES "$ROOT/scripts/mirror-dockerhub.sh" "$IMAGE" "$DST" 2>&1)" && bad "ran without NGINX_SERIES" \
    || { [[ "$out" == *"NGINX_SERIES is not set"* ]] && pass "NGINX_SERIES required"; } || bad "NGINX_SERIES message"
out="$("$ROOT/scripts/mirror-dockerhub.sh" "$IMAGE" "$IMAGE" 2>&1)" && bad "ran onto itself" \
    || { [[ "$out" == *"same image"* ]] && pass "refuses source = destination"; } || bad "same-image message"

[ "$FAILED" = 0 ] && echo "ALL MIRROR TESTS PASSED" || { echo "SOME MIRROR TESTS FAILED" >&2; exit 1; }
