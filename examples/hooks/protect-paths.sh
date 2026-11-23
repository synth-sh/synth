#!/usr/bin/env bash

exec python3 -c '
import fnmatch
import json
import os
import sys

try:
    payload = json.load(sys.stdin)
    path = payload["tool_input"]["path"]
    if not isinstance(path, str) or not path:
        raise ValueError("path must be a non-empty string")
    root = os.getcwd()
    absolute = os.path.abspath(os.path.join(payload.get("cwd", root), path))
    patterns = (".env", ".env.*", "*/.env", "*/.env.*", "*.lock", "*.lockb",
                "package-lock.json", ".github/*", ".gitlab-ci.yml", "Jenkinsfile",
                "src/core/migrations/*", "*.pem", "*.key", "*id_rsa*", "*id_ed25519*")
    for target in (absolute, os.path.realpath(absolute)):
        candidate = os.path.relpath(target, root) if os.path.commonpath((root, target)) == root else target
        if any(fnmatch.fnmatchcase(candidate, pattern) for pattern in patterns):
            print(f"{path} is protected", file=sys.stderr)
            sys.exit(2)
except Exception as error:
    print(f"Cannot validate path: {error}", file=sys.stderr)
    sys.exit(2)
'
