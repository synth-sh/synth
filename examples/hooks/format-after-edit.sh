#!/usr/bin/env bash
#
# PostToolUse hook for `edit` and `write`. Formats the tree so the agent does
# not spend turns on whitespace and the diff stays readable.
#
#   { "matcher": "^(edit|write)$", "hooks": [{ "command": "./examples/hooks/format-after-edit.sh" }] }
#
# Keep formatting failures quiet so the build can report them in context.
set -euo pipefail

# Reading stdin keeps synth from seeing a closed pipe while it writes.
cat >/dev/null

command -v zig >/dev/null || exit 0
zig fmt src build.zig >/dev/null 2>&1 || true
