#!/usr/bin/env bash
# Smoke test of a built nginx-proxy image: tests/smoke.sh <image>
# Runs the image the way the server does (same environment, Docker socket at /tmp/docker.sock,
# acme-companion's label), with a backend container behind it, on a private network; docker-gen is
# limited to that network (DOCKER_CONTAINER_FILTERS), so other containers of the engine are ignored.
# Two cases, each in its own proxy container:
#   upstream  the image's own /app/nginx.tmpl; the backend starts after the proxy (docker-gen -watch
#             must regenerate and reload on the event)
#   server    tests/fixtures/server-nginx.tmpl (the template ~/nginx-proxy mounts in production);
#             the backend is already there at startup
# Checked in both: nginx -t, HTTPS + HTTP/2 to a vhost with a certificate, HTTP -> HTTPS redirect,
# plain HTTP to a vhost without certificate, IPv6 listener, 503 for an unknown host. Plus the
# server template's own settings (client_max_body_size 0, Cloudflare real IP).
# Exits non-zero on the first failure.
set -euo pipefail

TARGET="${1:?usage: tests/smoke.sh <image>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
set -a
. "$ROOT/versions.env"
set +a
SERVER_TEMPLATE="${SERVER_TEMPLATE:-$ROOT/tests/fixtures/server-nginx.tmpl}"
# The backend: plain nginx, the official image the candidate is built on when build.sh runs us.
BACKEND_IMAGE="${BASE_IMAGE:-nginx:${NGINX_SERIES}-trixie}"

# Expected version: what build.sh read from the official image (exported), else the image's label.
NGINX_VERSION="${NGINX_VERSION:-$(docker image inspect -f '{{ index .Config.Labels "dev.nginx-proxy.nginx-version" }}' "$TARGET")}"
[ -n "$NGINX_VERSION" ] || { echo "FAIL: no expected nginx version (env or label)" >&2; exit 1; }
[ -f "$SERVER_TEMPLATE" ] || { echo "FAIL: no server template at ${SERVER_TEMPLATE}" >&2; exit 1; }

ID="nps-$$-${RANDOM}"
NET="$ID"
CONTAINERS=()
TMP="$(mktemp -d)"
cleanup() {
    docker rm -f ${CONTAINERS[@]+"${CONTAINERS[@]}"} >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT

PROXY=""
fail() {
    echo "FAIL: $*" >&2
    if [ -n "$PROXY" ]; then echo "--- proxy log (last 30 lines)" >&2; docker logs --tail 30 "$PROXY" >&2 2>&1 || true; fi
    exit 1
}
pass() { echo "ok   $*"; }

docker network create "$NET" >/dev/null

# A self-signed certificate for smoke.test, where acme-companion would put it (/etc/nginx/certs).
mkdir -p "$TMP/certs"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=smoke.test" -addext "subjectAltName=DNS:smoke.test" \
    -keyout "$TMP/certs/smoke.test.key" -out "$TMP/certs/smoke.test.crt" >/dev/null 2>&1 \
    || fail "openssl cannot create the test certificate"

backend() {   # starts the backend: smoke.test (has a certificate) and plain.test (has none)
    local cid
    cid="$(docker run -d --platform "$PLATFORM" --name "${ID}-backend" --network "$NET" \
        -e VIRTUAL_HOST=smoke.test,plain.test --entrypoint sh "$BACKEND_IMAGE" \
        -c 'echo smoke-backend-ok > /usr/share/nginx/html/index.html
            echo "client_max_body_size 0;" > /etc/nginx/conf.d/body.conf
            exec nginx -g "daemon off;"')"
    CONTAINERS+=("$cid")
}

# proxy <case> <template or "">: creates the proxy with the server's settings, copies the
# certificate (and the template) in, starts it, waits until nginx answers. Sets $PROXY.
proxy() {
    local name="$1" template="$2"
    PROXY="$(docker create --platform "$PLATFORM" --name "${ID}-proxy-${name}" --network "$NET" \
        --sysctl net.ipv6.conf.all.disable_ipv6=0 \
        -v /var/run/docker.sock:/tmp/docker.sock:ro \
        --label com.github.nginx-proxy.nginx-proxy \
        -e ENABLE_IPV6=true -e ENABLE_HTTP2=true -e ENABLE_HTTP3=false -e TRUST_DOWNSTREAM_PROXY=true \
        -e DOCKER_CONTAINER_FILTERS="network=${NET}" \
        "$TARGET")"
    CONTAINERS+=("$PROXY")
    docker cp "$TMP/certs/." "${PROXY}:/etc/nginx/certs/" >/dev/null
    [ -z "$template" ] || docker cp "$template" "${PROXY}:/app/nginx.tmpl" >/dev/null
    docker start "$PROXY" >/dev/null
    for _ in $(seq 1 100); do
        [ "$(docker inspect -f '{{.State.Running}}' "$PROXY")" = true ] || fail "${name}: the proxy exited"
        docker exec "$PROXY" curl -s -o /dev/null http://localhost/ 2>/dev/null && return 0
        sleep 0.2
    done
    fail "${name}: nginx never answered"
}

# in_proxy <curl args...>: one request from inside the proxy container
in_proxy() { docker exec "$PROXY" curl -s --max-time 5 "$@"; }

# wait_routed <case>: docker-gen has generated smoke.test and nginx reloaded
wait_routed() {
    for _ in $(seq 1 100); do
        [ "$(in_proxy -k --resolve smoke.test:443:127.0.0.1 https://smoke.test/ 2>/dev/null)" = smoke-backend-ok ] && return 0
        [ "$(docker inspect -f '{{.State.Running}}' "$PROXY")" = true ] || fail "$1: the proxy exited"
        sleep 0.2
    done
    fail "$1: smoke.test never reached the backend (docker-gen did not generate it, or nginx did not reload)"
}

expect() {   # expect <what> <expected> <curl args...>: status line "<code> <location>" of one request
    local what="$1" expected="$2" got
    shift 2
    got="$(in_proxy -o /dev/null -w '%{http_code} %header{location}' "$@")" || true
    [ "$got" = "$expected" ] || fail "${what}: got [${got}], expected [${expected}]"
    pass "${what}: ${got}"
}

routing_checks() {   # the checks both templates must pass
    local c="$1" got
    docker exec "$PROXY" nginx -t >/dev/null 2>&1 || fail "${c}: nginx -t rejects the generated configuration"
    pass "${c}: nginx -t accepts the generated configuration"
    got="$(in_proxy -k --http2 --resolve smoke.test:443:127.0.0.1 -o /dev/null -w '%{http_code} HTTP/%{http_version}' https://smoke.test/)"
    [ "$got" = "200 HTTP/2" ] || fail "${c}: HTTPS to smoke.test: got [${got}], expected [200 HTTP/2]"
    pass "${c}: HTTPS + HTTP/2 to the backend: ${got}"
    expect "${c}: HTTP to a vhost with a certificate redirects" "301 https://smoke.test/x?y=1" -H "Host: smoke.test" "http://localhost/x?y=1"
    got="$(in_proxy -H "Host: plain.test" http://localhost/)"
    [ "$got" = smoke-backend-ok ] || fail "${c}: HTTP to plain.test (no certificate): got [${got}]"
    pass "${c}: plain HTTP to a vhost without certificate reaches the backend"
    got="$(in_proxy -g -H "Host: plain.test" "http://[::1]/")"
    [ "$got" = smoke-backend-ok ] || fail "${c}: the IPv6 listener (ENABLE_IPV6) does not answer: got [${got}]"
    pass "${c}: IPv6 listener answers"
    expect "${c}: unknown host" "503 " -H "Host: unknown.test" "http://localhost/"
}

# 1. The image itself.
proxy upstream ""
v="$(docker exec "$PROXY" nginx -v 2>&1)"
[ "$v" = "nginx version: nginx/${NGINX_VERSION}" ] || fail "nginx -v is [$v], expected nginx/${NGINX_VERSION}"
pass "$v"
# our builds (ldflags of the Dockerfile): upstream's forego image answers "dev" here
got="$(docker exec "$PROXY" docker-gen -version 2>&1)" || fail "docker-gen does not run"
[ "$got" = "$DOCKER_GEN_VERSION" ] || fail "docker-gen -version is [$got], expected ${DOCKER_GEN_VERSION}"
got="$(docker exec "$PROXY" forego version 2>&1)" || fail "forego does not run"
[ "$got" = "$FOREGO_VERSION" ] || fail "forego version is [$got], expected ${FOREGO_VERSION}"
pass "docker-gen ${DOCKER_GEN_VERSION} and forego ${FOREGO_VERSION} (our builds)"
env_dump="$(docker exec "$PROXY" env)"
grep -qx "NGINX_PROXY_VERSION=${NGINX_PROXY_VERSION}" <<<"$env_dump" || fail "NGINX_PROXY_VERSION is not ${NGINX_PROXY_VERSION}"
grep -q '^DOCKER_GEN_VERSION=.' <<<"$env_dump" || fail "DOCKER_GEN_VERSION is not set (acme-companion reads it)"
pass "NGINX_PROXY_VERSION and DOCKER_GEN_VERSION set"

# 2. Upstream's template; the backend arrives after the proxy (the watch path).
backend
wait_routed upstream
pass "upstream: docker-gen picked up the backend started after the proxy"
routing_checks upstream
docker rm -f "$PROXY" >/dev/null

# 3. The server's template; the backend is already running.
proxy server "$SERVER_TEMPLATE"
wait_routed server
routing_checks server
conf="$(docker exec "$PROXY" cat /etc/nginx/conf.d/default.conf)"
grep -q 'real_ip_header CF-Connecting-IP;' <<<"$conf" || fail "server: the generated configuration has no Cloudflare real_ip_header"
pass "server: Cloudflare real IP configuration generated"
# client_max_body_size 0: a 2 MB POST reaches the backend (no limit there either; being static, it
# answers 405), instead of the proxy's 413 with nginx's 1 MB default
docker exec "$PROXY" sh -c 'head -c 2097152 /dev/zero > /tmp/body'
expect "server: a 2 MB upload reaches the backend (client_max_body_size 0)" "405 " -X POST --data-binary @/tmp/body \
    -H "Host: plain.test" "http://localhost/"

echo "all checks passed for $TARGET"
