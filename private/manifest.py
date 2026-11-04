#!/usr/bin/env python3
"""flagd_manifest: fill in manifests/flagd.yaml.tmpl.

  manifest.py TEMPLATE OUT IMAGE REPLICAS FLAG_FILE...

Each flag file becomes a ConfigMap key `<NN>-<basename>` (NN keeps the
source order and makes keys unique) as a YAML literal block, and a
`--uri file:/etc/flagd/<key>` argument, in order. The pod template gets
the SHA-256 of the keys and contents, so new flags roll the pods.
"""

import hashlib
import os
import re
import sys


def main(argv):
    template, out, image, replicas, *files = argv
    data, args = [], []
    digest = hashlib.sha256()
    for i, path in enumerate(files):
        base = re.sub(r"[^-._a-zA-Z0-9]", "_", os.path.basename(path))
        key = f"{i:02d}-{base}"
        with open(path) as f:
            text = f.read()
        text = text.lstrip("\n")
        if text[:1] in (" ", "\t"):
            print(f"flagd_manifest: {path}: the first line is indented; a ConfigMap "
                  f"literal block can't hold that. Unindent the file.", file=sys.stderr)
            return 1
        digest.update(key.encode() + b"\0" + text.encode() + b"\0")
        lines = text.rstrip("\n").split("\n")
        # Literal block, re-indented by 4 spaces; blank lines stay empty.
        block = [f"  {key}: |"] + [("    " + l) if l.strip() else "" for l in lines]
        data.append("\n".join(block))
        args += ["            - --uri", f"            - file:/etc/flagd/{key}"]
    with open(template) as f:
        manifest = f.read()
    manifest = (manifest
                .replace("__CONFIGMAP_DATA__", "\n".join(data))
                .replace("__ARGS__", "\n".join(args))
                .replace("__FLAGS_SHA256__", digest.hexdigest())
                .replace("__IMAGE__", image)
                .replace("__REPLICAS__", replicas))
    with open(out, "w") as f:
        f.write(manifest)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
