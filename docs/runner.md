# Runner for nginx-proxy-docker

nginx-proxy-docker runs on the **same amd64 VM runners** as frankenphp-docker and the other base
images (`base-images-amd64`, runner 2, and `base-images-amd64-2`, runner 3: shell executor, each
VM's own Docker engine). The VM itself is described
in `../frankenphp-docker/docs/runner.md`. This file lists only what nginx-proxy-docker adds.

## 1. Outbound access (in addition to the PHP bases' list)

- `nginx.org` (download page: the latest 1.30.x release, for the freshness check)
- `deb.debian.org` (`apt-get upgrade` in the Dockerfile, `tests/os-updates.sh`)
- `github.com` (docker-gen and forego at their release commits), `proxy.golang.org` and
  `sum.golang.org` (their modules, checked against go.sum)
- Our registry: `silent/go-docker` (the Go builders). The job token must be allowed on go-docker:
  deploy-automation's `tools/gitlab-setup.sh` does it.
- Docker Hub (pulls only): `nginx:1.30-trixie`, `nginx:1.30.5-trixie` (guard test),
  `nginxproxy/nginx-proxy`, `golang:1.27.2-trixie` (Go guard test),
  `debian:trixie-20250811` (negative test of `tests/os-updates.sh`), `aquasec/trivy`
- The smoke test mounts the VM's Docker socket read-only into the candidate (docker-gen reads it,
  limited to the test's own network) and creates a throwaway network.
- Disk: small (~250 MB images).

## 2. GitLab settings (none are in the repo)

1. Create the project `silent/nginx-proxy-docker`, then Settings > General > Visibility, project
   features, permissions > **CI/CD** on (our GitLab disables it on new projects).
2. **Both** runners, `base-images-amd64` and `base-images-amd64-2` > **add the tag
   `nginx-proxy-amd64`** (keep their other tags, "Run untagged jobs" stays off). Then the project >
   Settings > CI/CD > Runners > Project runners > **Enable for this project**, each of the two.
   (Done on 28 Oct 2026 through the API.)
3. **CI/CD > Variables**: nothing to add.
   - `NTFY_TOPIC` is an instance variable (deploy-automation's `tools/gitlab-setup.sh`).
   - `NTFY_TOKEN`: ntfy access token, if the server requires one to publish.
4. **Build > Pipeline schedules > New schedule**: `45 6 * * *`, timezone Europe/Paris, branch
   `main` (after nginx-redirect-docker at 06:30).
5. **Settings > Packages and registries > Cleanup policies**: **disabled**, as for the other bases
   (deploy-automation's `tools/clean-registry.sh` cleans; it keeps every tag a server runs).
6. **Settings > Repository > Protected branches**: `main` protected (only maintainers push), since a
   push to `main` publishes the image, and the protected variables are only given to protected
   branches.
7. deploy-automation's `tools/gitlab-setup.sh` adds the job token allowlist entries (the
   `trigger:dependents` job triggers deploy-automation).

## 3. First run

Settings done, push `main`, then Build > Pipelines > **Run pipeline** on `main`. A run takes 6-9
minutes (the negative tests start the proxy several times). The first run pushes; the next ones push
only when the content changed ("unchanged: … nothing pushed" in the build log otherwise).
