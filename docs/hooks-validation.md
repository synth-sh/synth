# Hook validation and review

Validated source commit: `ea1a95e` on `moar-hooks`.

## Review

Three rounds used five fresh `gpt-6.1-sol` reviewers each. Reviewers inspected
frozen candidates and connected callers without changing the tree. Their scopes
covered security and permission flow, transport and streaming, contracts and
composition, architecture and performance, and integration and test evidence.

| Round | Candidate | Reviewers | Confirmed findings | Fix commit |
| --- | --- | --- | --- | --- |
| 1 | `c97618d` | 5 | 5 | `0816d1e` |
| 2 | `0816d1e` | 5 | 3 | `58a5442` |
| 3 | `58a5442` | 5 | 1 | `ea1a95e` |

Round one fixed later-call human approval bypasses, nullable tool-filter crashes,
ignored request-stage exit-2 blockers, incorrect default-header replacement and
removal, and repeated full-context copying for streamed HTTP events.

Round two fixed later permission allowances overriding an explicit human ask,
large Ollama error bodies bypassing retry handling, and special compatibility
retries losing HTTP failure metadata or reconsidering a veto. An additional
owner check fixed transcript exports requested by the new hook stages.

Round three fixed ChatGPT retrying first-event adapter failures as HTTP 503.
The reporting reviewer checked the correction. Regression coverage preserves
the original errors for blockers, invalid phase effects, and reviewer tampering.
No confirmed review finding remains open.

Architecture checks compared OpenCode's request-transform placement and inspected
the vendored Ollama transport. The changes reuse the existing request and
provider boundaries and add no runtime dependencies.

## Repeatable checks

```sh
zig build test
zig build test-hook-requests
```

The final run passed 895 application tests and 105 MCP tests, with six skips.
The optional Python 3 CLI suite passed all eight groups against isolated
loopback servers, private configuration, and temporary databases. It verifies
actual routing, credential redaction, context provenance, tool filtering, generation
settings, four wire protocols, header replacement/removal, blocking failures,
event payload scope, transcript snapshots, retry ceilings and vetoes,
oversized errors, permission precedence, and immutable reviewer evidence.

Formatting and `git diff --check` passed. The prompt CLI smoke check and four
additional isolated CLI smoke suites passed for reviewer security, targeted
routing, workspace changes, and lifecycle ordering.

## Limits

Fake providers establish harness behavior, not live provider compatibility or
decision-model accuracy. Live OAuth/cloud calls and interactive TUI operation
were not exercised. Hooks run with process permissions; they do not supply an
OS sandbox. WebSockets, catalog transforms, and process monitors remain outside
this feature set.
