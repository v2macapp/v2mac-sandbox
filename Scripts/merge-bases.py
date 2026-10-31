#!/usr/bin/env python3
"""Prints bases.json: every listed file's bases, then this release's. A sandbox keeps showing store apps
built on an earlier sandbox's base, so a new release doesn't empty the store.
Usage: merge-bases.py <new digest> <bases file>...   A missing file counts as empty (the first release)."""
import json, os, sys, tempfile


def merge(new, paths):
    out = []
    for path in paths:
        if os.path.exists(path):
            out += [d for d in json.load(open(path))["allowed"] if d not in out]
    return {"allowed": out + ([new] if new not in out else [])}


if sys.argv[1:] == ["--selftest"]:
    with tempfile.TemporaryDirectory() as d:
        a, b = os.path.join(d, "a"), os.path.join(d, "b")
        json.dump({"allowed": ["x", "y"]}, open(a, "w"))
        json.dump({"allowed": ["y", "z"], "_comment": "ignored"}, open(b, "w"))
        assert merge("n", [a, b, os.path.join(d, "missing")]) == {"allowed": ["x", "y", "z", "n"]}
        assert merge("x", [a]) == {"allowed": ["x", "y"]}
    print("ok")
else:
    print(json.dumps(merge(sys.argv[1], sys.argv[2:])))
