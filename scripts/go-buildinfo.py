"""Checks the build information of a Go binary (tests/go-binaries.sh; offline cases in tests/unit.sh).

    go version -m <binary> | python3 -I scripts/go-buildinfo.py <name> <go version> <min go> "<module@version ...>"

Exit 0 when the binary was compiled by exactly <go version>, not below <min go>, and every
<module@version> of the list is in it at that version or newer (the fixed modules of versions.env);
exit 1 with a FAIL line per problem otherwise.
"""
import re
import sys


def ver(v):
    """v1.18.7 / 1.27.3 / v0.0.0-2020... -> comparable tuple of the numeric release part."""
    m = re.match(r"v?(\d+)\.(\d+)\.(\d+)", v)
    if not m:
        raise ValueError(f"not a version: {v}")
    return tuple(int(x) for x in m.groups())


def main(argv, text):
    if len(argv) != 5:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    name, want_go, min_go, bumps = argv[1:5]
    lines = text.splitlines()
    problems = []
    m = re.match(r"^\S+: go(\S+)$", lines[0]) if lines else None
    if not m:
        print(f"FAIL {name}: no build information (not a Go binary?)")
        return 1
    go = m[1]
    if go != want_go:
        problems.append(f"compiled by Go {go}, not {want_go}")
    elif ver(go) < ver(min_go):
        problems.append(f"compiled by Go {go}, below the floor {min_go}")
    deps = {}
    for line in lines[1:]:
        f = line.split()
        if len(f) >= 3 and f[0] in ("dep", "=>"):
            deps[f[1]] = f[2]
    for item in bumps.split():
        mod, _, fixed = item.partition("@")
        have = deps.get(mod)
        if have is None:
            problems.append(f"{mod} is not in the binary (expected >= {fixed})")
        elif ver(have) < ver(fixed):
            problems.append(f"{mod} is {have}, below the fixed {fixed}")
    if problems:
        for p in problems:
            print(f"FAIL {name}: {p}")
        return 1
    fixed = ", ".join(f"{i.split('@')[0]} {deps[i.split('@')[0]]}" for i in bumps.split()) or "no module raised"
    print(f"ok   {name}: Go {go} (floor {min_go}); {fixed}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv, sys.stdin.read()))
