# nginx-proxy-docker

[nginx-proxy](https://github.com/nginx-proxy/nginx-proxy) rebuilt every night on the official
**stable** nginx (`nginx:1.30-trixie`) with Debian's updates applied, tested, and published to
`registry.developpeur-freelance.io/silent/nginx-proxy-docker`. It is the reverse proxy in front of
everything on the server (`~/nginx-proxy`, host networking, with acme-companion beside it).

Why: upstream's releases pin an nginx and fall behind. `nginxproxy/nginx-proxy:1.11.6`, the latest
release, ships nginx 1.31.3, without the CVE fixes of 14 Oct 2026 (1.30.6 / 1.31.7), and docker-gen
and forego compiled with Go 1.26.5 and old modules (17 fixable HIGH CVEs). Here nginx comes from the
official image each night, docker-gen and forego are compiled on our go-docker (current Go, fixed
modules), and only nginx-proxy's own files are taken from an upstream release.

## What is in the image

| Piece | From | Pinned in |
|---|---|---|
| nginx + Debian | `nginx:1.30-trixie`, digest of the night, `apt-get upgrade` | `NGINX_SERIES`, floor `MIN_NGINX_VERSION` |
| `/app` (entrypoint, Procfile, default `nginx.tmpl`, dhparam groups), `network_internal.conf` | `nginxproxy/nginx-proxy:<version>` | `NGINX_PROXY_VERSION` |
| `docker-gen` | compiled from github.com/nginx-proxy/docker-gen at its release commit, on go-docker | `DOCKER_GEN_VERSION`, `DOCKER_GEN_COMMIT`, `go/docker-gen/go.mod` |
| `forego` | compiled from github.com/nginx-proxy/forego at its release commit, on go-docker | `FOREGO_VERSION`, `FOREGO_COMMIT`, `go/forego/go.mod` |
| Go | `registry.developpeur-freelance.io/silent/go-docker:1.27-trixie`, digest of the night | floor `MIN_GO_VERSION` |

**The Go binaries.** Upstream's tests run in the build (one skipped: `TestGetCurrentContainerEmpty`
expects not to run in a container, and fails that way on upstream's own module files too), with
our `go/<tool>/go.mod` + `go.sum`: upstream's, with the fixed modules of `DOCKER_GEN_GO_GET` /
`FOREGO_GO_GET` raised. `scripts/update-go-deps.sh` generates them in go-docker (never edit them);
the build refuses files generated for another commit. A Go fix reaches the image the night after
go-docker publishes it (go-docker runs before this pipeline).

The Dockerfile is upstream's `Dockerfile.debian` with those sources. The image behaves as
upstream's: same environment variables, same `/tmp/docker.sock`, same `DOCKER_GEN_VERSION` for
acme-companion. The server mounts its own template over `/app/nginx.tmpl`; a copy lives in
`tests/fixtures/server-nginx.tmpl` and is tested every night.

## Nightly build (GitLab CI)

```bash
./build.sh                               # build + every gate, nothing pushed
./build.sh --push                        # same + push the four tags, only if the content changed
./build.sh --push --force                # push even an unchanged content
NGINX_BASE_TAG=1.30.6-trixie ./build.sh  # on a given official tag (rollback, reproduction)
```

| Tag | Use |
|---|---|
| `1.30-trixie`, `latest` | moving: what the server pulls |
| `1.30.6-trixie` | latest build of that exact nginx |
| `1.30.6-trixie-YYYYMMDD` | never overwritten: for rollbacks |

**Pushed only when something changed.** Restarting nginx-proxy cuts every site for a few seconds, so
the server must only be offered a real change. `build.sh` labels the image with `io.silent.content`,
the sha256 of the installed Debian packages, the nginx version, the digests of docker-gen, forego
and upstream, and the Dockerfile + versions.env. If the moving tag already serves that fingerprint,
nothing is pushed (`FORCE_PUSH=1` on "Run pipeline" overrides).

Gates, in order (any failure: nothing pushed):

1. The official image ships a `1.30.x` nginx; the Dockerfile refuses a binary below
   `MIN_NGINX_VERSION` or different from the announced version (`tests/guard.sh` proves it).
2. With `--push`: never older than what `1.30-trixie` serves.
3. If nginx.org has a newer 1.30.x than the official image: ntfy alert, built anyway.
4. The Go guard (`scripts/go-guard.sh`, in both builder stages): each binary compiled by the Go
   go-docker announces, not below `MIN_GO_VERSION` (`tests/guard.sh` proves it refuses
   `golang:1.27.2`).
5. `tests/smoke.sh`: the candidate as a real proxy (server's environment, Docker socket, a backend
   container), once with upstream's template (backend started after the proxy: docker-gen's watch),
   once with the server's: `nginx -t`, HTTPS + HTTP/2, HTTP → HTTPS redirect, plain HTTP without
   certificate, IPv6 listener, 503 on unknown host; for the server template also the Cloudflare
   real IP and the unlimited upload size; `docker-gen -version` and `forego version` are ours.
6. `tests/go-binaries.sh`: the binaries' own build information (`go version -m`): the expected Go,
   every fixed module at its version or newer.
7. `tests/os-updates.sh`: no update from Debian's archive pending.
8. `tests/negative.sh`: broken variants (no docker-gen, HTTP/2 off, lying `nginx -v`) are rejected
   by the smoke test, an old trixie snapshot by `tests/os-updates.sh`.
9. `tests/scan.sh`: Trivy; refuses a fixable HIGH or CRITICAL (`GATE_SEVERITIES`) the published
   image does not already have.
10. Push from the tested image, moving tags last; the registry must then serve exactly that image.

Offline tests: `tests/unit.sh` (including `scripts/go-buildinfo.py` on the real `go version -m`
of upstream's binaries, refused, and of ours, accepted).

## On the server

`~/nginx-proxy/docker-compose.yml` runs
`registry.developpeur-freelance.io/silent/nginx-proxy-docker:${IMAGE_TAG:-1.30-trixie}`
(`container_name: nginx-proxy` stays: acme-companion finds it by that name). deploy-automation's
`refresh.sh` pulls the moving tag and, when it is a new image, asks at the end of the run whether
to restart the proxy; it checks the sites afterwards and goes back to the previous image if
something is wrong. Rollback by hand:
`cd ~/nginx-proxy && IMAGE_TAG=1.30.6-trixie-20261028 docker compose up -d --force-recreate nginx-proxy`.

## Maintenance

- nginx security release: nothing to do (the next nightly picks it up once the official image
  ships it); raise `MIN_NGINX_VERSION` so nothing older can be built.
- New upstream nginx-proxy release: port the server's template changes onto the new upstream
  `nginx.tmpl` (diff `tests/fixtures/server-nginx.tmpl` against the old upstream one), copy it to
  the server and to `tests/fixtures/`, then bump `NGINX_PROXY_VERSION`.
- Go fix: nothing to do (go-docker publishes it, the next nightly compiles with it); raise
  `MIN_GO_VERSION` on a Go security release.
- New docker-gen / forego release: set `*_VERSION` and `*_COMMIT` (full SHA of the tag), drop from
  `*_GO_GET` what upstream now requires, run `scripts/update-go-deps.sh`, review, commit. A CVE in
  another module: add it to `*_GO_GET` the same way.
- New stable series (1.32): change `NGINX_SERIES`, `MIN_NGINX_VERSION` and the guard's old image.
