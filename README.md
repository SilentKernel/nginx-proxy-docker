# nginx-proxy-docker

[nginx-proxy](https://github.com/nginx-proxy/nginx-proxy) rebuilt every night on the official
**stable** nginx (`nginx:1.30-trixie`) with Debian's updates applied, tested, and published to
`registry.developpeur-freelance.io/silent/nginx-proxy-docker`. It is the reverse proxy in front of
everything on the server (`~/nginx-proxy`, host networking, with acme-companion beside it).

Why: upstream's releases pin an nginx and fall behind. `nginxproxy/nginx-proxy:1.11.6`, the latest
release, ships nginx 1.31.3, without the CVE fixes of 14 Oct 2026 (1.30.6 / 1.31.7). Here nginx comes
from the official image each night; only nginx-proxy's own files are taken from an upstream release.

## What is in the image

| Piece | From | Pinned in |
|---|---|---|
| nginx + Debian | `nginx:1.30-trixie`, digest of the night, `apt-get upgrade` | `NGINX_SERIES`, floor `MIN_NGINX_VERSION` |
| `/app` (entrypoint, Procfile, default `nginx.tmpl`, dhparam groups), `network_internal.conf` | `nginxproxy/nginx-proxy:<version>` | `NGINX_PROXY_VERSION` |
| `docker-gen` | `nginxproxy/docker-gen:<version>-debian` | `DOCKER_GEN_VERSION` |
| `forego` | `nginxproxy/forego:<version>-debian` | `FOREGO_VERSION` |

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
4. `tests/smoke.sh`: the candidate as a real proxy (server's environment, Docker socket, a backend
   container), once with upstream's template (backend started after the proxy: docker-gen's watch),
   once with the server's: `nginx -t`, HTTPS + HTTP/2, HTTP → HTTPS redirect, plain HTTP without
   certificate, IPv6 listener, 503 on unknown host; for the server template also the Cloudflare
   real IP and the unlimited upload size.
5. `tests/os-updates.sh`: no update from Debian's archive pending.
6. `tests/negative.sh`: broken variants (no docker-gen, HTTP/2 off, lying `nginx -v`) are rejected
   by the smoke test, an old trixie snapshot by `tests/os-updates.sh`.
7. `tests/scan.sh`: Trivy; refuses a fixable CRITICAL the published image does not already have.
8. Push from the tested image, moving tags last; the registry must then serve exactly that image.

Offline tests: `tests/unit.sh`.

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
- New stable series (1.32): change `NGINX_SERIES`, `MIN_NGINX_VERSION` and the guard's old image.
