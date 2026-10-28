# Runner for nginx-proxy-docker

nginx-proxy-docker runs on the **same amd64 VM runner** as frankenphp-docker and the other base
images (`base-images-amd64`, shell executor, the VM's own Docker engine). The VM itself is described
in `../frankenphp-docker/docs/runner.md`. This file lists only what nginx-proxy-docker adds.

## 1. Outbound access (in addition to the PHP bases' list)

- `nginx.org` (download page: the latest 1.30.x release, for the freshness check)
- `deb.debian.org` (`apt-get upgrade` in the Dockerfile, `tests/os-updates.sh`)
- Docker Hub (pulls only): `nginx:1.30-trixie`, `nginx:1.30.5-trixie` (guard test),
  `nginxproxy/nginx-proxy`, `nginxproxy/docker-gen`, `nginxproxy/forego`,
  `debian:trixie-20250811` (negative test of `tests/os-updates.sh`), `aquasec/trivy`
- The smoke test mounts the VM's Docker socket read-only into the candidate (docker-gen reads it,
  limited to the test's own network) and creates a throwaway network.
- Disk: small (~250 MB images).

## 2. GitLab settings (none are in the repo)

1. Create the project `silent/nginx-proxy-docker`, then Settings > General > Visibility, project
   features, permissions > **CI/CD** on (our GitLab disables it on new projects).
2. The `base-images-amd64` runner > **add the tag `nginx-proxy-amd64`** (keep its other tags, "Run
   untagged jobs" stays off). Then the project > Settings > CI/CD > Runners > Project runners >
   **Enable for this project**.
3. **CI/CD > Variables** (protected, masked where secret):
   - `NTFY_TOPIC`: `gitlab-ci-alert-x564789`, the alerts topic of every project.
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

Settings done, push `main`, then Build > Pipelines > **Run pipeline** on `main`. A run takes 4-6
minutes (the negative tests start the proxy several times). The first run pushes; the next ones push
only when the content changed ("unchanged: … nothing pushed" in the build log otherwise).
