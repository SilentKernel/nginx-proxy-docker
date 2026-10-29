# nginx-proxy-docker

[nginx-proxy](https://github.com/nginx-proxy/nginx-proxy), the automated Docker reverse proxy,
**rebuilt every night** on the official **stable** nginx (`nginx:1.30-trixie`) with Debian's
updates applied, its Go binaries compiled with a current Go, tested as a real proxy, and scanned
before it is published.

It is a drop-in replacement for `nginxproxy/nginx-proxy`: same `/app`, same environment variables,
same Docker socket path, works with
[acme-companion](https://github.com/nginx-proxy/acme-companion). It is the proxy in front of our own
production sites, and the image is public: use it if it is useful to you.

```bash
docker pull silentk/nginx-proxy-docker:1.30-trixie
```

## Why

Upstream's releases pin an nginx and fall behind between releases. On 28 Oct 2026,
`nginxproxy/nginx-proxy:1.11.6` (the latest release) shipped nginx 1.31.3, without the security
fixes of 14 Oct 2026 (nginx 1.30.6 / 1.31.7), and docker-gen and forego compiled with Go 1.26.5 and
old modules (17 fixable HIGH CVEs in Trivy). This image:

- starts each night from the official `nginx:1.30-trixie` (nginx.org's stable branch, Debian 13),
  then runs `apt-get upgrade`: an nginx or Debian fix lands the night it is published;
- compiles **docker-gen** and **forego** from their upstream release commits with the current Go
  1.27.x and the vulnerable modules raised to their fixed versions;
- takes only nginx-proxy's own files (`/app`: entrypoint, Procfile, default `nginx.tmpl`, dhparam
  groups) from the upstream release image, unchanged.

It follows nginx's **stable** branch (1.30.x), not mainline: fewer changes, security fixes only.

## Use it

Wherever you run `nginxproxy/nginx-proxy`, use `silentk/nginx-proxy-docker:1.30-trixie` instead.
The [nginx-proxy documentation](https://github.com/nginx-proxy/nginx-proxy/tree/main/docs) applies
as is (`VIRTUAL_HOST`, `VIRTUAL_PORT`, certificates, custom templates…).

```yaml
# docker-compose.yml
services:
  nginx-proxy:
    image: silentk/nginx-proxy-docker:1.30-trixie
    container_name: nginx-proxy
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/tmp/docker.sock:ro
      - certs:/etc/nginx/certs
      - html:/usr/share/nginx/html

  # Optional: Let's Encrypt certificates (https://github.com/nginx-proxy/acme-companion)
  acme-companion:
    image: nginxproxy/acme-companion
    volumes_from:
      - nginx-proxy
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - acme:/etc/acme.sh
    environment:
      - DEFAULT_EMAIL=mail@yourdomain.tld

  whoami:   # an example backend
    image: jwilder/whoami
    expose:
      - "8000"
    environment:
      - VIRTUAL_HOST=whoami.example
      - VIRTUAL_PORT=8000

volumes:
  certs:
  html:
  acme:
```

```bash
docker compose up -d
curl -H "Host: whoami.example" localhost     # I'm <container id>
```

### Tags

| Tag | What it is |
|---|---|
| `1.30-trixie`, `latest` | moving: the latest tested build of nginx 1.30.x. Use this one. |
| `1.30.6-trixie` | the latest build of that exact nginx version |
| `1.30.6-trixie-YYYYMMDD` | one build, never overwritten: pin it, or roll back to it |

A new image is pushed **only when its content changed** (a Debian package, nginx, Go, docker-gen,
forego, upstream's files): restarting the proxy cuts every site for a few seconds, so a pull of the
moving tag only brings you something new when there is something new. Most nights, nothing is
pushed. To be told, watch the tags on
[Docker Hub](https://hub.docker.com/r/silentk/nginx-proxy-docker/tags), or let a tool like
Watchtower or Diun do it.

`linux/amd64` only.

### Where to pull it from

The same image (same manifest digest) is published to two registries:

- **Docker Hub**: `silentk/nginx-proxy-docker` (recommended for you).
- Our registry, where it is built and pushed first:
  `registry.developpeur-freelance.io/silent/nginx-proxy-docker` (anonymous pulls allowed). Docker
  Hub receives a copy of each push a few minutes later.

### Check what you run

Every image carries labels describing its build:

```bash
docker buildx imagetools inspect silentk/nginx-proxy-docker:1.30-trixie \
    --format '{{json .Image.Config.Labels}}' | python3 -m json.tool
```

`dev.nginx-proxy.nginx-version`, `dev.nginx-proxy.upstream-version` (nginx-proxy release of
`/app`), `dev.nginx-proxy.go-version`, `dev.nginx-proxy.docker-gen` / `dev.nginx-proxy.forego`
(version + upstream commit), `org.opencontainers.image.base.digest` (the official nginx image it was
built on), `org.opencontainers.image.revision` (commit of this repository). Inside the container:
`nginx -v`, `docker-gen -version`, `forego version`.

### Differences from upstream's image

- Debian (trixie) only: there is no Alpine variant.
- nginx stable (1.30.x) instead of the mainline version upstream's release pins.
- docker-gen and forego are ours (same upstream code and version, current Go and modules), so
  `DOCKER_GEN_VERSION` is upstream's, as acme-companion expects.

Not affiliated with the nginx-proxy project; report image-specific issues here, nginx-proxy
behaviour issues upstream.

## What is tested before each push

Any failure and nothing is pushed:

1. nginx is a 1.30.x release, not below a security floor (`MIN_NGINX_VERSION`) and never older than
   what is already published.
2. docker-gen and forego are compiled by the expected Go, not below a floor (`MIN_GO_VERSION`),
   with upstream's own Go tests passing; their build information (`go version -m`) shows every
   fixed module at its fixed version or newer.
3. A real proxy run (`tests/smoke.sh`): Docker socket, a backend container started after the proxy
   (docker-gen's watch), `nginx -t`, HTTPS + HTTP/2, HTTP → HTTPS redirect, plain HTTP without a
   certificate, IPv6 listener, 503 on an unknown host; with upstream's template and with our
   production template (`tests/fixtures/server-nginx.tmpl`).
4. No Debian update pending in the image.
5. Negative tests: broken variants (no docker-gen, HTTP/2 off, a lying `nginx -v`, an old Debian
   snapshot) must be caught by the tests above.
6. Trivy: no fixable HIGH or CRITICAL CVE that the published image does not already have.
7. After the push, the registry must serve exactly the tested image.

## Build it yourself

Needs Docker with buildx, `python3`, `curl` and `git`. The build reads public images only.

```bash
./build.sh                               # build + every test above, nothing pushed
NGINX_BASE_TAG=1.30.6-trixie ./build.sh  # on a given official nginx tag (reproduce a build)
tests/unit.sh                            # offline tests of the scripts (seconds, no Docker)
```

The result is tagged locally as `registry.developpeur-freelance.io/silent/nginx-proxy-docker:1.30-trixie`.
Every setting lives in `versions.env`: to publish your own copy, change `IMAGE` (and, if you want
your own Go builder, `GO_BASE_IMAGE`). Go is the `go-docker` image (Go 1.27 on Debian trixie, also
rebuilt nightly), readable anonymously.

### How the image is made

| Piece | From | Pinned in |
|---|---|---|
| nginx + Debian | `nginx:1.30-trixie`, digest of the night, `apt-get upgrade` | `NGINX_SERIES`, floor `MIN_NGINX_VERSION` |
| `/app` (entrypoint, Procfile, default `nginx.tmpl`, dhparam groups), `network_internal.conf` | `nginxproxy/nginx-proxy:<version>` | `NGINX_PROXY_VERSION` |
| `docker-gen` | compiled from github.com/nginx-proxy/docker-gen at its release commit | `DOCKER_GEN_VERSION`, `DOCKER_GEN_COMMIT`, `go/docker-gen/go.mod` |
| `forego` | compiled from github.com/nginx-proxy/forego at its release commit | `FOREGO_VERSION`, `FOREGO_COMMIT`, `go/forego/go.mod` |
| Go | `registry.developpeur-freelance.io/silent/go-docker:1.27-trixie`, digest of the night | floor `MIN_GO_VERSION` |

The Dockerfile is upstream's `Dockerfile.debian` with those sources. Upstream's Go tests run in the
build (one skipped: `TestGetCurrentContainerEmpty` expects not to run in a container, and fails that
way on upstream's own module files too), with `go/<tool>/go.mod` + `go.sum`: upstream's, with the
modules of `DOCKER_GEN_GO_GET` / `FOREGO_GO_GET` raised. `scripts/update-go-deps.sh` generates them
(never edit them by hand); the build refuses files generated for another commit.

## For maintainers

Everything below is about our own CI and server.

### Nightly pipeline (GitLab CI)

`.gitlab-ci.yml` runs on our amd64 runners (`docs/runner.md`): every night, on a push to `main` and
on "Run pipeline". On `main` the `build` job runs `./build.sh --push`; elsewhere (merge requests,
other branches) it only builds and tests.

```bash
./build.sh --push          # build + test + push the four tags, only if the content changed
./build.sh --push --force  # push even an unchanged content (FORCE_PUSH=1 on "Run pipeline")
```

**Content fingerprint.** `build.sh` labels the image with `io.silent.content`: the sha256 of the
installed Debian packages, the nginx and Go versions, the digest of upstream's image, the
Dockerfile, `versions.env`, the Go guard and the `go/` module files. If the moving tag already
serves that fingerprint, nothing is pushed (the tests still run: they are the nightly health check).
Anything added to `versions.env` changes the fingerprint, hence one new image.

Notifications go to our ntfy (`scripts/notify.sh`, `NTFY_TOPIC`): a new image (on `NTFY_TOPIC_NEWBASE` (the important channel: something to roll out)), the official image
lagging behind nginx.org's latest 1.30.x (built anyway), a failed pipeline, a failed Docker Hub copy.
After a publish, `trigger:dependents` asks deploy-automation to rebuild what is built on this image.

### Docker Hub copy

Job `mirror:dockerhub` (`scripts/mirror-dockerhub.sh`), after `build` on every publishing
pipeline, also when nothing was pushed: copies what our registry serves, registry to registry
(`docker buildx imagetools create --prefer-index=false`, same digest), tag by tag, only what Docker
Hub lacks or serves differently, so a missed night is repaired by the next one. It is
`allow_failure` (Docker Hub down never blocks a publish) and alerts on ntfy when it fails.

- `DOCKERHUB_IMAGE` is in `.gitlab-ci.yml`, not in `versions.env` (the fingerprint, above).
- `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` (masked, protected): project CI/CD variables. The token
  is a Docker Hub personal access token "gitlab-ci nginx-proxy-docker mirror", Repo Read & Write,
  no expiry. To rotate: create a new one, replace `DOCKERHUB_TOKEN`, run a pipeline, revoke the old.
- `tests/mirror.sh`: the copy against a throwaway local registry (four tags with identical
  manifests and blobs, a second run copies nothing, a wrong tag is repaired alone, an unreachable
  destination fails and alerts).

### On our server

`~/nginx-proxy/docker-compose.yml` runs
`registry.developpeur-freelance.io/silent/nginx-proxy-docker:${IMAGE_TAG:-1.30-trixie}` (host
network, `container_name: nginx-proxy`: acme-companion finds it by that name) with our template
mounted over `/app/nginx.tmpl` (a copy in `tests/fixtures/server-nginx.tmpl`, tested every night).
deploy-automation's `refresh.sh` pulls the moving tag and, when it is a new image, asks whether to
restart the proxy, checks the sites afterwards and goes back to the previous image if one fails.
Rollback by hand:
`cd ~/nginx-proxy && IMAGE_TAG=1.30.6-trixie-20261028 docker compose up -d --force-recreate nginx-proxy`.
If our registry is lost, point `image:` at `silentk/nginx-proxy-docker` (same tags).

### Maintenance

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
