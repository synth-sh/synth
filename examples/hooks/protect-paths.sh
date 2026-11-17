#!/usr/bin/env bash
set -euo pipefail

if ! command -v python3 >/dev/null; then
  cat >/dev/null
  echo 'path protection requires python3' >&2
  exit 2
fi

exec python3 -c '
import fnmatch
import json
import os
import sys

try:
    path = json.load(sys.stdin).get("tool_input", {}).get("path", "")
    if not isinstance(path, str):
        raise ValueError("path must be a string")
    root = os.getcwd()
    absolute = os.path.abspath(os.path.join(root, path))
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
