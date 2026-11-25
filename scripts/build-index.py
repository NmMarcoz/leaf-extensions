#!/usr/bin/env python3
"""Generate index.json — the one file Leaf reads from this repository.

Never hand-edit index.json. It is written from the scripts themselves, loaded
through Leaf's real sandbox (`leaf sources verify --json`), so the manifest
fields it lists are the ones the app will actually see and the sha256 is of
the exact bytes the app will download.

    scripts/build-index.py           rewrite index.json
    scripts/build-index.py --check   exit 1 if index.json is stale (CI, hook)

The `leaf` binary is found as $LEAF_BIN, else on PATH.

Deterministic on purpose, so --check can compare byte for byte:
- entries sorted by file;
- `version` is carried over from the committed index while a script's sha256
  is unchanged, and only becomes today's (UTC) date when the bytes change;
- `generated` is the newest `version`, not the time this ran.
"""

import datetime
import json
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INDEX = os.path.join(ROOT, "index.json")
KIND_DIRS = ["metadata", "enrich", "readers"]
SCHEMA = 1
NAME = "Leaf extensions"

# Manifest fields copied into each entry, in this order.
FIELDS = [
    "id",
    "name",
    "kind",
    "lang",
    "base_url",
    "mirrors",
    "description",
    "api",
    "nsfw",
    "capabilities",
]


def leaf_binary():
    found = os.environ.get("LEAF_BIN") or shutil.which("leaf")
    if not found:
        sys.exit("build-index: no `leaf` binary — set LEAF_BIN or put it on PATH")
    return found


def verified_manifests():
    dirs = [d for d in KIND_DIRS if os.path.isdir(os.path.join(ROOT, d))]
    result = subprocess.run(
        [leaf_binary(), "sources", "verify", "--json", *dirs],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    sys.stderr.write(result.stderr)
    if result.returncode != 0:
        sys.exit("build-index: verification failed; fix the scripts above first")
    return json.loads(result.stdout)


def previous_versions():
    try:
        with open(INDEX, encoding="utf-8") as f:
            old = json.load(f)
    except (OSError, ValueError):
        return {}
    return {s["file"]: (s.get("sha256"), s.get("version")) for s in old.get("scripts", [])}


def build():
    previous = previous_versions()
    today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    scripts = []
    for manifest in verified_manifests():
        file = os.path.relpath(os.path.join(ROOT, manifest["file"]), ROOT).replace(os.sep, "/")
        old_sha, old_version = previous.get(file, (None, None))
        version = old_version if old_sha == manifest["sha256"] and old_version else today
        entry = {"file": file}
        for field in FIELDS:
            entry[field] = manifest.get(field)
        entry["sha256"] = manifest["sha256"]
        entry["version"] = version
        scripts.append(entry)
    scripts.sort(key=lambda s: s["file"])
    generated = max((s["version"] for s in scripts), default=today)
    index = {"schema": SCHEMA, "name": NAME, "generated": generated, "scripts": scripts}
    return json.dumps(index, indent=2, ensure_ascii=False) + "\n"


def main():
    check = "--check" in sys.argv[1:]
    fresh = build()
    if check:
        try:
            with open(INDEX, encoding="utf-8") as f:
                committed = f.read()
        except OSError:
            committed = ""
        if committed != fresh:
            sys.exit(
                "index.json is stale. Regenerate it and commit the result:\n\n"
                "    python3 scripts/build-index.py\n"
            )
        print("index.json is up to date")
        return
    with open(INDEX, "w", encoding="utf-8") as f:
        f.write(fresh)
    count = len(json.loads(fresh)["scripts"])
    print(f"wrote index.json ({count} scripts)")


if __name__ == "__main__":
    main()
