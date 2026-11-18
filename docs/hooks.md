# Hooks

Hooks run reviewed commands or MCP tools at points in Synth's agent loop.
They can observe activity, supply context, prepare model requests, or enforce
permission policies. Hooks run with your process permissions, not in a sandbox.

## Configure and review

Declarations load from `config.json`'s `hooks`, `~/.synth/hooks.json`, then
`<project>/.synth/hooks.json`. A hooks file contains either an event map or a
`{"hooks": {...}}` object.

```json
{
  "PreToolUse": [{
    "matcher": "^(write|edit)$",
    "hooks": [{"type": "command", "command": "python3 \"$SYNTH_PROJECT_DIR/.synth/protect-paths.py\""}]
  }]
}
```

Commands run from the original project root. The JSON input's `cwd` reports
the session working directory. Changing directories doesn't change hook lookup
or grant access to another file root; `/add-dir` explicitly grants that access.

Use `/hooks review` or `synth hooks review` to inspect declarations, then
`trust <id>` or `disable <id>` to proceed. Granting trust or enabling a hook requires at least 32 ID characters. Other
actions accept an unambiguous prefix of at least eight characters. `revoke`, `enable`, and `list` are also available.

Existing hooks need review before new prompts run. Changed declarations need
fresh trust. User-level commands with absolute executable and file paths share trust across
projects. Relative commands and project hook sources remain tied to their checkout. Changing the default timeout doesn't reset trust.
Trust covers declarations, not the contents or dependencies of external scripts.
Direct file-tool edits to control files and literal paths named by trusted
commands require human approval. Shell commands and MCP tools can have other
side effects and follow their normal approval policy. Trust does not provide
filesystem isolation for those processes.

The [path-protection example](../examples/hooks/protect-paths.py) rejects writes
to secrets, CI files, lockfiles, and migrations, including equivalent paths and
symlinks. Place it under `.synth/` and match `write|edit`.

Built-in file hooks expose `file_path`, `old_string`, and `new_string` alongside
Synth's field names, including batched edits. `updatedInput` accepts either
spelling; conflicting changes reject the call. MCP arguments are preserved.

## Handlers and matching

Grouped handlers use `type: "command"` by default. `timeout_ms` is milliseconds and `timeout` is seconds;
the default is 30 seconds. `async: true` runs a handler in the background and
permits context or diagnostics only. Request preparation and permission
evaluation must run synchronously. Background work is bounded and excess work
is reported without waiting on the UI thread.

`type: "mcp_tool"` requires `server`, `tool`, and `arguments`. Arguments support
`${input.field.path}` interpolation; a whole-string reference preserves its JSON
type. MCP handlers are synchronous and aren't supported during session shutdown.

Grouped matchers use bounded regexes, with tool-name aliases such as `Bash` and
`Read`. File-change matchers are literal project-root filenames separated by
`|`. Legacy `{ "matcher": "write", "command": "..." }` lists keep exact matching,
serial execution, and ignored stdout.

### Targeted routing

Add `when` beside `matcher` and `hooks` to require matching `agent_scope`
(`main` or `subagent`), `agent_type`, `model`, `provider`, or `request_purpose`
(`agent`, `approval_judge`, or `compaction`). All supplied conditions must match.
Child inputs include parent agent and tool-call identifiers.

## Events

| Events | Control |
| --- | --- |
| `SessionStart`, `UserPromptSubmit` | Supply context or block admission |
| `UserPromptExpansion`, `ConfigChange`, `PreModelSwitch` | Reject the proposed operation |
| `PreToolUse` | Reject, request approval, replace arguments, or supply context |
| `PermissionEvaluate`, `PermissionRequest` | Deny or request human approval for a prepared action |
| `PostToolUse`, `PostToolUseFailure` | Successful results accept feedback/context; failures accept context/diagnostics |
| `PostToolBatch` | Supply context or stop before the next model request |
| `TaskCreated`, `TaskCompleted` | Reject a todo-list change |
| `PreCompact`, `PostCompact` | Stop compaction or its automatic continuation |
| `Stop`, `SubagentStop` | Request further work within the existing turn budgets |
| `SessionEnd`, `SubagentStart`, `Interrupt`, `StopFailure`, `PermissionDenied`, `Notification`, `InstructionsLoaded`, `FileChanged`, `PostModelSwitch`, `CwdChanged`, `DirectoryAdded` | Observe only |
| `MessageDisplay` | Replace displayed text; stored/model-visible text stays unchanged |
| `PreModelRequest`, `PostModelRequest` | Observe each physical transport attempt |
| `ModelResolve`, `ModelSettings`, `ModelContext`, `ModelRetry` | Prepare a request or decide a retry |
| `HttpRequest`, `HttpResponse` | Adapt inference HTTP payloads |

`FileChanged` observes configured files, including external writes. Workspace
change events report completed transitions. `SubagentStart` cannot reject child
creation; child tool operations still pass the normal policies.

## Input and output

Commands receive one JSON object on stdin. Common fields include
`hook_event_name`, `cwd`, session/turn/agent identifiers, scope, request purpose,
model, and provider. Tool events include `tool_name`, `tool_input` (an object),
and call identifiers; result events include `tool_response` (a string).

`action`, `http`, and `request_*` values are **JSON-encoded strings**, not nested
objects. For example, use `jq '.action | fromjson | .resolved_targets'`.
Set `transcript: true` to request a private JSONL snapshot; `transcript_path` is
null when unavailable. Shutdown and interrupt handlers have short bounded limits.

Grouped handlers may return JSON on stdout:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "This file is protected"
  }
}
```

Exit 2 blocks supported operations using stderr as the reason. Missing commands,
spawn failures, and malformed synchronous policy outputs fail closed. Other
nonzero command exits are advisory. Observational failures report diagnostics.

Independent handler outputs merge in declaration order. Denial and explicit ask
remain binding; tool selections intersect; context edits append; later
rewrites win. An `allow` output leaves normal approval policy unchanged; hooks
cannot grant permission. A denial cannot be reversed by another handler. Post-tool hooks
cannot undo side effects that already happened.

## Model requests

`ModelResolve` receives conversation/tool history and public route metadata.
Return `hookSpecificOutput.route` to select a route declared in `model_requests`.
Routes restrict endpoint, model, credentials, and allowed purposes. See
[Configuration](configuration.md) for route settings.

`ModelSettings` returns `settings`, including supported sampling/output controls,
reasoning effort, `attempts`, and `retry_delay_ms`. Unsupported settings fail
before transport. Attempts bound failure retries; one compatibility/authentication
repair may occur independently. Retry hooks can veto that repair too.

`ModelContext` accepts `requestContext` with optional `system`, `instruction`,
`tools` (existing tool names), and `messages`. Message edits identify `seq` and
may replace `text`, omit a plain message, omit attachments/images/thinking, or
replace tool results using `tool_results: [{"call_id":"...","text":"..."}]`.
Edits affect a request-owned copy. Tool exchanges must remain complete, excluded
tools cannot execute, and approval-review evidence cannot be rewritten.

`ModelRetry` receives the attempt, HTTP status, error type/message, eligibility,
and proposed delay. Return `retryAllowed` or `retryDelayMs` to change the decision.
Cancellation, bounded delays, and no retries after delivered output still apply.

## HTTP adapters

`http` describes `phase`, `method`, `url`, `protocol`, `status`, `headers`, `body`,
and stream `index`. Request phases accept `http.headers` and replacement JSON
`http.body`. The response `headers` phase accepts headers/status; the `body`
phase accepts replacement JSON. Header values are strings or null for removal.
Known credential headers are redacted in input.

Per-record response processing is off by default. Set `stream: true` on each
`HttpResponse` handler that needs SSE/NDJSON events. It may replace `http.body` or
set `http.drop: true`. Each matching record invokes a handler; command handlers
start a process, so use this only when record-level adaptation is necessary.

Adapters support Chat, Responses, Messages, and Ollama inference. They can't
change destinations, routed models, connection framing, or reviewer evidence.
They don't intercept discovery, OAuth, tool web requests, or WebSockets.

## Compatibility

Synth shares many Claude Code event names and decision conventions, but does not
load Claude/Codex plugins or settings files. Payloads use Synth's tool arguments,
and timeouts use `timeout_ms`. See the official
[Claude Code reference](https://code.claude.com/docs/en/hooks) for that product's
contract.

Run `zig build test` for module tests and isolated offline CLI tests. The latter
require Python 3 and can also run with `zig build test-hook-requests`.
