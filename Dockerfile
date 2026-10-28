# syntax=docker/dockerfile:1
# nginx-proxy on the official stable nginx (Debian trixie). Same layout as upstream's
# Dockerfile.debian (nginx-proxy 1.11.6), but the nginx comes from nginx:<series>-trixie and Debian's
# updates are applied at every build. build.sh passes every image pinned by digest.
ARG BASE_IMAGE=nginx:1.30-trixie
ARG DOCKER_GEN_IMAGE=nginxproxy/docker-gen:0.17.2-debian
ARG FOREGO_IMAGE=nginxproxy/forego:0.18.8-debian
ARG UPSTREAM_IMAGE=nginxproxy/nginx-proxy:1.11.6

FROM ${DOCKER_GEN_IMAGE} AS docker-gen
FROM ${FOREGO_IMAGE} AS forego
FROM ${UPSTREAM_IMAGE} AS upstream

FROM ${BASE_IMAGE}

ARG NGINX_VERSION
ARG MIN_NGINX_VERSION
ARG NGINX_PROXY_VERSION
ARG DOCKER_GEN_VERSION

# Debian security fixes without waiting for the official image to be rebuilt; never cached (build.sh
# builds with --no-cache), tests/os-updates.sh then checks none is left. The official image removes
# nginx.org's apt source after installing nginx: this cannot move nginx (see nginx-redirect-docker).
RUN set -eu; \
    apt-get update -o APT::Update::Error-Mode=any; \
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -o Dpkg::Options::=--force-confold; \
    rm -rf /var/lib/apt/lists/*

# Refuse to produce a vulnerable image: the nginx binary must be the version build.sh expects and
# not below the floor (versions.env).
RUN set -eu; \
    test -n "${NGINX_VERSION}" && test -n "${MIN_NGINX_VERSION}"; \
    actual="$(nginx -v 2>&1 | sed -n 's|^nginx version: nginx/||p')"; \
    echo "nginx ${actual} expected=${NGINX_VERSION} required>=${MIN_NGINX_VERSION}"; \
    [ "${actual}" = "${NGINX_VERSION}" ] || { echo "nginx is ${actual}, not ${NGINX_VERSION}" >&2; exit 1; }; \
    lowest="$(printf '%s\n%s\n' "${actual}" "${MIN_NGINX_VERSION}" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)"; \
    if [ "${lowest}" != "${MIN_NGINX_VERSION}" ]; then \
        echo "nginx ${actual} is older than ${MIN_NGINX_VERSION}: refusing to build a vulnerable image" >&2; \
        exit 1; \
    fi

# acme-companion reads DOCKER_GEN_VERSION (its value does not matter, upstream's comment);
# docker-gen reads the Docker socket the compose file mounts at /tmp/docker.sock.
ENV NGINX_PROXY_VERSION=${NGINX_PROXY_VERSION} \
    DOCKER_GEN_VERSION=${DOCKER_GEN_VERSION} \
    DOCKER_HOST=unix:///tmp/docker.sock

# Upstream's nginx.conf changes, verbatim (Dockerfile.debian of nginx-proxy 1.11.6).
RUN echo "\ninclude /etc/nginx/toplevel.conf.d/*.conf;" >> /etc/nginx/nginx.conf \
   && sed -i 's/worker_connections.*;$/worker_connections  10240;/' /etc/nginx/nginx.conf \
   && sed -i -e '/^\}$/{s//\}\nworker_rlimit_nofile 20480;/;:a' -e '$!N;$!ba' -e '}' /etc/nginx/nginx.conf \
   && mkdir -p '/etc/nginx/toplevel.conf.d' \
   && mkdir -p '/etc/nginx/dhparam' \
   && mkdir -p '/etc/nginx/certs' \
   && mkdir -p '/usr/share/nginx/html/errors'

COPY --from=forego /usr/local/bin/forego /usr/local/bin/forego
COPY --from=docker-gen /usr/local/bin/docker-gen /usr/local/bin/docker-gen
COPY --from=upstream /etc/nginx/network_internal.conf /etc/nginx/network_internal.conf
COPY --from=upstream /app/ /app/
WORKDIR /app/

ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["forego", "start", "-r"]
