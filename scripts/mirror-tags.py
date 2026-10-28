"""Digest and tags of the image our moving tag serves, for scripts/mirror-dockerhub.sh.

    docker buildx imagetools inspect <image>:<series>-trixie --format '{{json .}}' \
        | python3 -I scripts/mirror-tags.py <series> <platform>

Prints the top-level digest, then the four tags build.sh gave that image, in push order (moving
tags last): <nginx>-trixie-YYYYMMDD, <nginx>-trixie, <series>-trixie, latest. The nginx version and
the date come from the image's labels (dev.nginx-proxy.nginx-version,
org.opencontainers.image.created: build.sh's TAG_DATED is that build's UTC date). Fails on missing
or malformed labels: the mirror must never invent a tag.
"""
import json
import re
import sys


def fail(msg):
    print(f"mirror-tags: {msg}", file=sys.stderr)
    sys.exit(1)


def main():
    if len(sys.argv) != 3:
        fail("usage: mirror-tags.py <series> <platform> < inspect.json")
    series, platform = sys.argv[1], sys.argv[2]
    try:
        d = json.load(sys.stdin)
    except ValueError as e:
        fail(f"not the JSON of imagetools inspect: {e}")
    digest = (d.get("manifest") or {}).get("digest") or ""
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        fail(f"no top-level digest (got '{digest}')")
    image = d.get("image") or {}
    if "config" not in image:   # multi-platform index: one entry per platform
        image = image.get(platform) or {}
    labels = (image.get("config") or {}).get("Labels") or {}
    nginx = labels.get("dev.nginx-proxy.nginx-version") or ""
    if not re.fullmatch(re.escape(series) + r"\.[0-9]+", nginx):
        fail(f"label dev.nginx-proxy.nginx-version is '{nginx}', not a {series}.x release")
    created = labels.get("org.opencontainers.image.created") or ""
    m = re.fullmatch(r"(\d{4})-(\d{2})-(\d{2})T\d{2}:\d{2}:\d{2}Z", created)
    if not m:
        fail(f"label org.opencontainers.image.created is '{created}', not a UTC timestamp")
    print(digest)
    print(f"{nginx}-trixie-{''.join(m.groups())}")
    print(f"{nginx}-trixie")
    print(f"{series}-trixie")
    print("latest")


main()
