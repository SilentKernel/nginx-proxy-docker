#!/usr/bin/env bash
# Unit tests of the scripts in scripts/: offline, no Docker, a few seconds. Needs python3 and curl.
#   tests/unit.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/tests/fixtures"
FAILED=0

pass() { echo "ok   $*"; }
bad() { echo "FAIL $*" >&2; FAILED=1; }

expect_ok() {   # <name> <expected output> <command...>
    local name="$1" expected="$2" out
    shift 2
    if out="$("$@")" && [ "$out" = "$expected" ]; then pass "$name"; else bad "$name: got [$out]"; fi
}

expect_fail() {   # <name> <expected message part> <command...>
    local name="$1" msg="$2" out
    shift 2
    if out="$("$@")"; then bad "$name: succeeded with [$out]"
    elif [[ "$out" == *"$msg"* ]]; then pass "$name"
    else bad "$name: failed, but with [$out]"; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"; [ -z "${server_pid:-}" ] || kill "$server_pid" 2>/dev/null || true' EXIT

echo "--- resolve-versions.sh"
# Runs the resolver offline on a download page, with extra VAR=value assignments.
resolve() {
    env -i PATH="$PATH" NGINX_SERIES=1.30 NGINX_DOWNLOAD_HTML_FILE="$FIX/nginx-download.html" \
        "$@" "$ROOT/scripts/resolve-versions.sh" 2>&1
}
expect_ok "latest 1.30.x of the real nginx.org page (mainline 1.31.x and legacy 1.28.x ignored)" \
    "NGINX_LATEST=1.30.6" resolve
expect_ok "mainline series when asked" "NGINX_LATEST=1.31.8" resolve NGINX_SERIES=1.31
printf '<a href="/download/nginx-1.30.9.tar.gz">x</a> <a href="/download/nginx-1.30.10.tar.gz">y</a>
<a href="/download/nginx-1.30.2.tar.gz.asc">pgp</a> <a href="/download/nginx-1.300.1.tar.gz">z</a>' > "$tmp/many.html"
expect_ok "1.30.10 > 1.30.9 (numeric, not lexical); 1.300.x is not 1.30.x" \
    "NGINX_LATEST=1.30.10" resolve NGINX_DOWNLOAD_HTML_FILE="$tmp/many.html"
expect_fail "series absent from the page" "no nginx 1.29.x release" resolve NGINX_SERIES=1.29
echo '<html>maintenance</html>' > "$tmp/maint.html"
expect_fail "maintenance page" "no nginx 1.30.x release" resolve NGINX_DOWNLOAD_HTML_FILE="$tmp/maint.html"
: > "$tmp/empty.html"
expect_fail "empty answer" "no nginx 1.30.x release" resolve NGINX_DOWNLOAD_HTML_FILE="$tmp/empty.html"
expect_fail "NGINX_SERIES unset" "NGINX_SERIES is not set" \
    bash -c '"$@" 2>&1' _ env -i PATH="$PATH" NGINX_DOWNLOAD_HTML_FILE="$FIX/nginx-download.html" "$ROOT/scripts/resolve-versions.sh"

echo "--- version-compare.sh (no-downgrade, freshness)"
cmp() { "$ROOT/scripts/version-compare.sh" "$@" && echo allowed || echo refused; }
expect_ok "1.30.5 -> 1.30.6 allowed" allowed cmp 1.30.5 1.30.6
expect_ok "1.30.6 -> 1.30.5 refused" refused cmp 1.30.6 1.30.5
expect_ok "1.30.9 -> 1.30.10 allowed (numeric, not lexical)" allowed cmp 1.30.9 1.30.10
expect_ok "1.30.10 -> 1.30.9 refused (numeric, not lexical)" refused cmp 1.30.10 1.30.9
expect_ok "same version allowed (nightly rebuild with Debian fixes)" allowed cmp 1.30.6 1.30.6
expect_ok "nothing published yet allowed" allowed cmp "" 1.30.6

echo "--- trivy-diff.py (vulnerability gate)"
vuln() { printf '{"VulnerabilityID": "%s", "PkgName": "%s", "Severity": "%s", "FixedVersion": "9"}' "$@"; }
printf '{"Results": [{"Vulnerabilities": [%s, %s]}]}' "$(vuln CVE-1 libssl3 CRITICAL)" "$(vuln CVE-2 curl HIGH)" > "$tmp/t-pub.json"
printf '{"Results": [{"Vulnerabilities": [%s]}]}' "$(vuln CVE-1 libssl3 CRITICAL)" > "$tmp/t-same.json"
printf '{"Results": [{"Vulnerabilities": [%s, %s]}]}' "$(vuln CVE-1 libssl3 CRITICAL)" "$(vuln CVE-3 libxml2 CRITICAL)" > "$tmp/t-new.json"
printf '{"Results": [{"Target": "x", "Vulnerabilities": null}]}' > "$tmp/t-clean.json"
td() { env -u GATE_SEVERITIES python3 -I "$ROOT/scripts/trivy-diff.py" "$@" 2>&1; }
tdh() { GATE_SEVERITIES=HIGH,CRITICAL python3 -I "$ROOT/scripts/trivy-diff.py" "$@" 2>&1; }
printf '{"Results": [{"Vulnerabilities": [%s, %s]}]}' "$(vuln CVE-1 libssl3 CRITICAL)" "$(vuln CVE-4 stdlib HIGH)" > "$tmp/t-newhigh.json"
echo "  (default GATE_SEVERITIES=CRITICAL, as the other images)"
expect_ok "a CRITICAL the published image already has: pass" \
    "$(printf '  info candidate: 1 fixable CRITICAL, 0 fixable HIGH\n  info 1 fixable HIGH/CRITICAL of the published image fixed by the candidate\n  ok   no fixable CRITICAL the published image does not already have')" \
    td "$tmp/t-same.json" "$tmp/t-pub.json"
expect_fail "a new fixable CRITICAL: refused" "CVE-3 in libxml2, CRITICAL (fixed in 9)" td "$tmp/t-new.json" "$tmp/t-pub.json"
expect_ok "a new fixable HIGH: pass (not gated by default)" \
    "$(printf '  info candidate: 1 fixable CRITICAL, 1 fixable HIGH\n  info 1 fixable HIGH/CRITICAL of the published image fixed by the candidate\n  ok   no fixable CRITICAL the published image does not already have')" \
    td "$tmp/t-newhigh.json" "$tmp/t-pub.json"
expect_ok "clean candidate: pass" \
    "$(printf '  info candidate: 0 fixable CRITICAL, 0 fixable HIGH\n  info 2 fixable HIGH/CRITICAL of the published image fixed by the candidate\n  ok   no fixable CRITICAL the published image does not already have')" \
    td "$tmp/t-clean.json" "$tmp/t-pub.json"
expect_ok "nothing published yet: report only" \
    "$(printf '  info candidate: 2 fixable CRITICAL, 0 fixable HIGH\n  info no published image to compare with: report only')" \
    td "$tmp/t-new.json" ""
echo "  (GATE_SEVERITIES=HIGH,CRITICAL, this image's setting)"
expect_fail "a new fixable HIGH: refused" "CVE-4 in stdlib, HIGH (fixed in 9)" tdh "$tmp/t-newhigh.json" "$tmp/t-pub.json"
expect_fail "a new fixable CRITICAL: refused" "new fixable HIGH/CRITICAL in the candidate" tdh "$tmp/t-new.json" "$tmp/t-pub.json"
expect_ok "a HIGH the published image already has: pass" \
    "$(printf '  info candidate: 1 fixable CRITICAL, 1 fixable HIGH\n  info 0 fixable HIGH/CRITICAL of the published image fixed by the candidate\n  ok   no fixable HIGH/CRITICAL the published image does not already have')" \
    tdh "$tmp/t-pub.json" "$tmp/t-pub.json"
expect_ok "clean candidate: pass" \
    "$(printf '  info candidate: 0 fixable CRITICAL, 0 fixable HIGH\n  info 2 fixable HIGH/CRITICAL of the published image fixed by the candidate\n  ok   no fixable HIGH/CRITICAL the published image does not already have')" \
    tdh "$tmp/t-clean.json" "$tmp/t-pub.json"

echo "--- served-ids.py (post-push check)"
ids() { python3 -I "$ROOT/scripts/served-ids.py" "$@" 2>&1; }
expect_ok "single manifest: top digest + config digest" "$(printf 'sha256:top\nsha256:cfg')" \
    ids sha256:top '{"config": {"digest": "sha256:cfg"}}' linux/amd64
expect_ok "index: asks for our platform's manifest" "need-child sha256:amd" \
    ids sha256:top '{"manifests": [{"digest": "sha256:arm", "platform": {"os": "linux", "architecture": "arm64"}}, {"digest": "sha256:amd", "platform": {"os": "linux", "architecture": "amd64"}}]}' linux/amd64
expect_ok "index + child: top, platform manifest, config" "$(printf 'sha256:top\nsha256:amd\nsha256:cfg')" \
    ids sha256:top '{"manifests": [{"digest": "sha256:amd", "platform": {"os": "linux", "architecture": "amd64"}}]}' linux/amd64 '{"config": {"digest": "sha256:cfg"}}'
expect_ok "--digest: the human-readable block of an old buildx gives the top digest" "sha256:f2b3670d7396b5df0e0e613842405e847850baa247c7468e229f57dd392d8462" \
    sh -c 'printf "Name:      r\nMediaType: m\nDigest:    sha256:f2b3670d7396b5df0e0e613842405e847850baa247c7468e229f57dd392d8462\n" | python3 -I "$1" --digest' _ "$ROOT/scripts/served-ids.py"
expect_ok "--digest: the JSON of .Manifest" "sha256:f2b3670d7396b5df0e0e613842405e847850baa247c7468e229f57dd392d8462" \
    sh -c 'printf "{\"mediaType\": \"m\", \"digest\": \"sha256:f2b3670d7396b5df0e0e613842405e847850baa247c7468e229f57dd392d8462\"}" | python3 -I "$1" --digest' _ "$ROOT/scripts/served-ids.py"
expect_fail "--digest: an answer without a digest is refused" "no top-level digest" \
    sh -c 'printf "Name:      r\n" | python3 -I "$1" --digest 2>&1' _ "$ROOT/scripts/served-ids.py"
expect_fail "a top that is not a digest is refused" "the top digest is not a digest" \
    sh -c 'python3 -I "$1" "Name:      r" "{\"config\": {\"digest\": \"sha256:cfg\"}}" linux/amd64 2>&1' _ "$ROOT/scripts/served-ids.py"

echo "--- mirror-tags.py (Docker Hub backup: the tags of the published image)"
# tests/fixtures/mirror/inspect-1.30-trixie.json: `imagetools inspect --format '{{json .}}'` of
# 1.30-trixie on 28 Oct 2026 (its tags then: 1.30.6-trixie-20261028, 1.30.6-trixie, latest).
mt() { python3 -I "$ROOT/scripts/mirror-tags.py" "$@" 2>&1; }
mt_json() {   # <python expression changing d> <series>: the fixture, modified
    python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); L = d["image"]["config"]["Labels"]; exec(sys.argv[2]); print(json.dumps(d))' \
        "$FIX/mirror/inspect-1.30-trixie.json" "$1" | mt "$2" linux/amd64
}
expect_ok "real image: digest, then the four tags in push order (moving last)" "$(printf '%s\n' \
    sha256:63ae785711c775767c9871997afd92350d851e762589ae7f07e0ef9c53b5e926 \
    1.30.6-trixie-20261028 1.30.6-trixie 1.30-trixie latest)" \
    sh -c 'python3 -I "$1" 1.30 linux/amd64 < "$2"' _ "$ROOT/scripts/mirror-tags.py" "$FIX/mirror/inspect-1.30-trixie.json"
expect_ok "multi-platform index: our platform's labels" "$(printf '%s\n' sha256:"$(printf 'a%.0s' $(seq 64))" \
    1.30.7-trixie-20261231 1.30.7-trixie 1.30-trixie latest)" \
    mt_json 'd["manifest"]["digest"] = "sha256:" + "a" * 64; L["dev.nginx-proxy.nginx-version"] = "1.30.7"; L["org.opencontainers.image.created"] = "2026-12-31T23:59:59Z"; d["image"] = {"linux/arm64": {}, "linux/amd64": d["image"]}' 1.30
expect_fail "no nginx label: refused" "dev.nginx-proxy.nginx-version is ''" mt_json 'del L["dev.nginx-proxy.nginx-version"]' 1.30
expect_fail "nginx of another series: refused" "is '1.30.6', not a 1.31.x release" mt_json 'pass' 1.31
expect_fail "1.300.1 is not 1.30.x" "not a 1.30.x release" mt_json 'L["dev.nginx-proxy.nginx-version"] = "1.300.1"' 1.30
expect_fail "no created label: refused" "org.opencontainers.image.created is ''" mt_json 'del L["org.opencontainers.image.created"]' 1.30
expect_fail "created not in UTC: refused" "not a UTC timestamp" mt_json 'L["org.opencontainers.image.created"] = "2026-10-28T03:36:17+02:00"' 1.30
expect_fail "no digest: refused" "no top-level digest" mt_json 'd["manifest"] = {}' 1.30
expect_fail "not JSON: refused" "not the JSON of imagetools inspect" sh -c 'echo "Name: x" | python3 -I "$1" 1.30 linux/amd64 2>&1' _ "$ROOT/scripts/mirror-tags.py"

echo "--- notify.sh"
expect_ok "no NTFY_TOPIC: skipped, exit 0" "notify: NTFY_TOPIC not set, skipped: t" \
    env -u NTFY_TOPIC "$ROOT/scripts/notify.sh" high warning t m

# A local ntfy stand-in that records each request as JSON lines.
port="$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 -I - "$port" "$tmp/requests.jsonl" <<'PY' &
import http.server, json, sys
port, log = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        with open(log, "a") as f:
            f.write(json.dumps({"path": self.path, "headers": dict(self.headers), "body": body}) + "\n")
        self.send_response(200); self.end_headers(); self.wfile.write(b"{}")
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b"{}")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
server_pid=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null && break; sleep 0.1; done

# env -i: in CI, CI_PIPELINE_URL (and maybe NTFY_TOKEN) are already set and would leak in.
env -i PATH="$PATH" NTFY_URL="http://127.0.0.1:$port" NTFY_TOPIC=nginx-test NTFY_TOKEN=tk_secret \
    CI_PIPELINE_URL=https://git.example/p/1 "$ROOT/scripts/notify.sh" urgent "rotating_light" "Build failed" "smoke test failed" >/dev/null
env -i PATH="$PATH" NTFY_URL="http://127.0.0.1:$port" NTFY_TOPIC=nginx-test "$ROOT/scripts/notify.sh" default "" "No token" "plain" >/dev/null
if python3 -I - "$tmp/requests.jsonl" <<'PY'
import json, sys
r = [json.loads(l) for l in open(sys.argv[1])]
assert len(r) == 2, r
a, b = r
assert a["path"] == "/nginx-test", a
assert a["headers"]["Title"] == "Build failed" and a["headers"]["Priority"] == "urgent", a
assert a["headers"]["Tags"] == "rotating_light" and a["headers"]["Click"] == "https://git.example/p/1", a
assert a["headers"]["Authorization"] == "Bearer tk_secret" and a["body"] == "smoke test failed", a
assert "Authorization" not in b["headers"] and "Click" not in b["headers"] and b["body"] == "plain", b
PY
then pass "topic, title, priority, tags, click URL, bearer token and body sent; no token header without NTFY_TOKEN"
else bad "notify request content"; fi

echo "--- build.sh: the new-base message goes to NTFY_TOPIC_NEWBASE, never to NTFY_TOPIC"
# The exact call of build.sh (from its package,arrow_up line to the end of the command), run against
# the stand-in: a version bump is the one message of the important channel (refresh the server).
newbase_call="$(awk '/package,arrow_up/ {on=1} on {print; if ($0 !~ /\\$/) exit}' "$ROOT/build.sh")"
if [ "$(grep -c 'package,arrow_up' "$ROOT/build.sh")" = 1 ] \
    && grep -qF 'NTFY_TOPIC="${NTFY_TOPIC_NEWBASE:-}" "$ROOT/scripts/notify.sh" default "package,arrow_up"' <<<"$newbase_call"
then pass "build.sh sends its one new-base message with NTFY_TOPIC=\${NTFY_TOPIC_NEWBASE}"
else bad "build.sh new-base message not on NTFY_TOPIC_NEWBASE: [$newbase_call]"; fi
sent_before="$(wc -l < "$tmp/requests.jsonl")"
env -i PATH="$PATH" ROOT="$ROOT" NTFY_URL="http://127.0.0.1:$port" NTFY_TOPIC=main-test NTFY_TOPIC_NEWBASE=newbase-test \
    bash -c "$newbase_call" >/dev/null
if tail -n +"$((sent_before + 1))" "$tmp/requests.jsonl" | python3 -I -c '
import json, sys
r = [json.loads(l) for l in sys.stdin]
assert [x["path"] for x in r] == ["/newbase-test"], r
assert r[0]["headers"]["Tags"] == "package,arrow_up", r
'
then pass "new base: one request, to the NTFY_TOPIC_NEWBASE topic, none to NTFY_TOPIC"
else bad "new-base request did not go (only) to NTFY_TOPIC_NEWBASE"; fi
sent_before="$(wc -l < "$tmp/requests.jsonl")"
out="$(env -i PATH="$PATH" ROOT="$ROOT" NTFY_URL="http://127.0.0.1:$port" NTFY_TOPIC=main-test bash -c "$newbase_call")"
if [[ "$out" == "notify: NTFY_TOPIC not set, skipped: "* ]] && [ "$(wc -l < "$tmp/requests.jsonl")" = "$sent_before" ]
then pass "NTFY_TOPIC_NEWBASE unset: new-base message skipped, not sent to NTFY_TOPIC"
else bad "NTFY_TOPIC_NEWBASE unset: got [$out]"; fi

kill "$server_pid"; wait "$server_pid" 2>/dev/null || true; server_pid=""
expect_ok "unreachable server: exit 0, error only logged" "" \
    env NTFY_URL="http://127.0.0.1:$port" NTFY_TOPIC=t "$ROOT/scripts/notify.sh" high x t m

echo "--- os-updates.sh (Debian updates gate)"
# tests/os-updates.sh on captured `apt-get -s upgrade / dist-upgrade` outputs (tests/fixtures/apt/,
# shared with ../python-docker; pending.txt is python-docker's published image of 24 Oct 2026, before
# CVE-2026-111497's libbrotli1 fix).
osu() { env OS_UPDATES_FILE="$FIX/apt/$1.txt" "$ROOT/tests/os-updates.sh" image 2>&1; }
expect_fail "os-updates: Debian security updates pending -> refused" "FAIL 7 Debian update(s) missing" osu pending
expect_fail "os-updates: names the package and both versions" "libbrotli1 1.1.0-2+b7 -> 1.1.0-2+deb13u1" osu pending
expect_fail "os-updates: stable-updates counts too" "tzdata 2026c-0+deb13u1 -> 2026e-0+deb13u1" osu pending
expect_ok "os-updates: nothing pending -> accepted" "  ok   no Debian update pending" osu clean
expect_ok "os-updates: a third-party repository (nginx.org) is not counted" "  ok   no Debian update pending" osu third-party
expect_ok "os-updates: what only dist-upgrade would do is a warning" "$(printf '%s\n' \
    "  WARNING only dist-upgrade would apply (new or removed packages; not done, a human decides):" \
    "    libfoo-common none -> 1.0-1+deb13u1" "    libfoo-old1 removed" "    libfoo1 1.0-1 -> 1.0-1+deb13u1" \
    "  ok   no Debian update pending")" osu kept-back
printf 'Err:1 http://deb.debian.org/debian trixie InRelease\n' >"$tmp/apt-broken.txt"
expect_fail "os-updates: an apt output without both simulations -> refused" "FAIL unexpected apt-get output" \
    env OS_UPDATES_FILE="$tmp/apt-broken.txt" "$ROOT/tests/os-updates.sh" image

echo "--- Go binaries: go-buildinfo.py on real \`go version -m\` outputs, go/ module files"
set -a; . "$ROOT/versions.env"; set +a
GM="$FIX/go-version-m"
gbi_as() { local f="$1"; shift; python3 -I "$ROOT/scripts/go-buildinfo.py" "$@" < "$GM/$f.txt" 2>&1; }
expect_fail "upstream's docker-gen 0.17.2 (Go 1.26.5) is refused: old Go" "FAIL docker-gen: compiled by Go 1.26.5, not 1.27.3" \
    gbi_as upstream-docker-gen docker-gen 1.27.3 "$MIN_GO_VERSION" "$DOCKER_GEN_GO_GET"
expect_fail "upstream's docker-gen is refused: compress below the fixed version" "FAIL docker-gen: github.com/klauspost/compress is v1.18.4, below the fixed v1.18.7" \
    gbi_as upstream-docker-gen docker-gen 1.27.3 "$MIN_GO_VERSION" "$DOCKER_GEN_GO_GET"
expect_fail "upstream's docker-gen is refused: go-archive and x/crypto too" "golang.org/x/crypto is v0.52.0, below the fixed v0.55.0" \
    gbi_as upstream-docker-gen docker-gen 1.27.3 "$MIN_GO_VERSION" "$DOCKER_GEN_GO_GET"
expect_fail "upstream's forego v0.18.8 is refused: x/text" "FAIL forego: golang.org/x/text is v0.14.0, below the fixed v0.41.0" \
    gbi_as upstream-forego forego 1.27.3 "$MIN_GO_VERSION" "$FOREGO_GO_GET"
expect_fail "announced Go matching an old binary is still below the floor" "compiled by Go 1.26.5, below the floor $MIN_GO_VERSION" \
    gbi_as upstream-forego forego 1.26.5 "$MIN_GO_VERSION" ""
expect_ok "our docker-gen passes" "ok   docker-gen: Go 1.27.3 (floor $MIN_GO_VERSION); github.com/klauspost/compress v1.18.7, github.com/moby/go-archive v0.3.0, golang.org/x/crypto v0.55.0" \
    gbi_as ours-docker-gen docker-gen 1.27.3 "$MIN_GO_VERSION" "$DOCKER_GEN_GO_GET"
expect_ok "our forego passes" "ok   forego: Go 1.27.3 (floor $MIN_GO_VERSION); golang.org/x/text v0.41.0" \
    gbi_as ours-forego forego 1.27.3 "$MIN_GO_VERSION" "$FOREGO_GO_GET"
expect_fail "a module of the list missing from the binary is refused" "example.com/absent is not in the binary" \
    gbi_as ours-forego forego 1.27.3 "$MIN_GO_VERSION" "example.com/absent@v1.0.0"
printf 'not a go binary\n' > "$tmp/notgo.txt"
expect_fail "no build information: refused" "no build information" \
    sh -c 'python3 -I "$1" x 1.27.3 1.27.3 "" < "$2"' _ "$ROOT/scripts/go-buildinfo.py" "$tmp/notgo.txt"
for tool in docker-gen forego; do
    case "$tool" in docker-gen) commit="$DOCKER_GEN_COMMIT" bumps="$DOCKER_GEN_GO_GET" ;; *) commit="$FOREGO_COMMIT" bumps="$FOREGO_GO_GET" ;; esac
    [ "$(head -1 "$ROOT/go/$tool/go.mod")" = "// generated by scripts/update-go-deps.sh for ${commit}: do not edit" ] \
        && pass "go/$tool/go.mod was generated for ${commit:0:12} (versions.env)" \
        || bad "go/$tool/go.mod is not for ${commit}: run scripts/update-go-deps.sh"
    for b in $bumps; do
        grep -qE "^\s*(require\s+)?${b%@*} ${b#*@}( |$)" "$ROOT/go/$tool/go.mod" \
            && pass "go/$tool/go.mod requires ${b%@*} ${b#*@}" || bad "go/$tool/go.mod does not require ${b%@*} ${b#*@}: run scripts/update-go-deps.sh"
    done
done

if [ "$FAILED" = 0 ]; then echo "all unit tests passed"; else echo "unit tests FAILED" >&2; exit 1; fi
