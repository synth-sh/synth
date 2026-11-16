# Hooks

Hooks run trusted local commands or already-connected MCP tools at agent lifecycle
boundaries. The TUI, ACP, headless mode, and task subagents share the runtime.
Commands run from the project root and receive one JSON object on stdin.

## Upgrade and trust

**Existing hooks require a one-time review after this upgrade.** No declaration
is automatically trusted, including legacy inline hooks. Inspect definitions
before trusting their exact ids:

```sh
synth hooks list
synth hooks review
synth hooks trust <id>
synth hooks disable <id>
synth hooks enable <id>
synth hooks revoke <id>
```

The TUI offers the same operations through `/hooks`, `/hooks review`, and
`/hooks trust <id>` (and `disable`, `enable`, `revoke`). ACP clients can use the
`_synth/hooks` request with `sessionId`, `action`, and `id`, or the `/hooks`
command. Review and list return the sources, matchers, modes, timeouts, trust
state, and recent execution records. Mutation requires an idle session.
Headless mode reports pending review and does not submit the prompt.

Trust is stored in the user's private data directory as `hook-trust.json`;
debug builds use the `synth-dev` directory, never the project database. Trust
covers the project and source identity, declaration position, event, matcher,
handler, arguments, effective timeout, and control settings. A changed definition
gets a different id. Disabling retains trust; re-enabling does not grant it.
Review the new id after editing configuration, then trust it explicitly.
Trust authorizes the declaration; it does not freeze a referenced shell script
or sandbox its effects. Scripts may change after a declaration is trusted.

## Configuration and compatibility

Declarations load additively, in this order:

1. The `hooks` object in synth's loaded `config.json`.
2. `~/.synth/hooks.json` (when a home directory is available).
3. `<project-root>/.synth/hooks.json`.

Each separate file can contain the event object directly or wrap it in `hooks`.
Project definitions do not replace user definitions. Duplicates remain separate
declarations. `/hooks` reloads the separate hook files while the session is idle;
changes to the main config take effect on restart.

Flat definitions retain legacy behavior: exact tool matchers, serial execution,
ignored stdout, and advisory post-tool exits. Exiting 2 blocks prompt/pre-tool
operations, including when stderr is empty. Execution failures before an
operation fail closed. The default timeout remains 30 seconds, and the working
directory remains the project root.

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "bash", "command": "./scripts/check-command.sh" }
    ]
  }
}
```

Grouped definitions opt into structured stdout, regex matchers, and concurrent
execution. Do not mix the flat `command` and grouped `hooks` keys in one entry.

```json
{
  "hooks": {
    "PreToolUse": [{
      "matcher": "^(Bash|Write|Edit)$",
      "hooks": [{
        "type": "command",
        "command": "./scripts/policy.sh",
        "timeout_ms": 5000,
        "transcript": true
      }]
    }],
    "PostToolUse": [{
      "matcher": "^(Write|Edit)$",
      "hooks": [{
        "type": "command",
        "command": "./scripts/check-and-report.sh",
        "async": true
      }]
    }]
  }
}
```

Timeouts must be integers from 1 through 86,400,000 milliseconds, including the
shared `hook_timeout_ms` default. Handler overrides use `timeout_ms`.
`SessionEnd` and `Interrupt` use a one-second handler default, a three-second
handler ceiling, and a three-second total cleanup deadline. `SessionEnd` accepts
only synchronous command handlers.

For grouped tool events, `*` or an empty matcher selects every tool. Otherwise
the matcher is a regex over the canonical name or its alias: `bash`/`Bash`,
`read`/`Read`, `write`/`Write`, `edit`/`Edit`, and `task`/`Agent`. A matching alias
does not cause a second invocation. Payload tool names remain synth's canonical
names. Non-tool event matchers are ignored. Supported regex syntax is literals,
`.`, character classes, anchors, groups, alternation, `\d`, `\w`, `\s` and their
negations, word boundaries, and greedy/lazy `* + ? {n,m}`. Backreferences,
lookaround, special groups, and other alphabetic escapes are rejected. Resource
exhaustion is a visible policy failure. Each match owns its scratch memory;
Rust-regex language compatibility is not implied.

## Events and effects

| Event | When it runs | Supported control |
| --- | --- | --- |
| `SessionStart` | Before the first request after startup, resume, clear, or successful compaction | Context or stop |
| `SessionEnd` | Orderly main-session shutdown, after workers stop | Diagnostics only |
| `UserPromptSubmit` | New prompts and steering, before persistence | Denial or context |
| `PreToolUse` | Every admitted tool identity, before approval and checkpoints | Denial, context, replacement arguments, or request approval |
| `PermissionRequest` | A call otherwise needs an approval decision | Allow once, deny, or leave normal flow in force |
| `PostToolUse` | A completed tool result, including error results | Feedback or context; side effects remain |
| `PreCompact` | Before manual or automatic compaction | Stop while preserving history |
| `PostCompact` | After successful compaction | Stop automatic resumption |
| `SubagentStart` | Child startup | Context and diagnostics; cannot deny creation |
| `SubagentStop` | Child completion, before its parent receives the answer | Request more child work |
| `Stop` | Normal root-turn completion | Request more work within the existing budgets |
| `Interrupt` | Explicit cancellation of a busy root turn, once | Diagnostics only |
| `PreModelRequest` | Each actual request attempt, including retries, classification, and compaction | Diagnostics only |
| `PostModelRequest` | Exactly once per attempt, completed/failed/cancelled | Diagnostics and available usage |

Session-start hooks are deferred until a prompt needs the session. Cancelling
or a failed/blocked start does not admit that prompt. Completion continuations
set `stop_hook_active`, carry an attributed reason, and retain the original
turn's time, token, and step limits. Cancellation does not invoke completion
hooks. Child shutdown does not emit main-session `SessionEnd`.

## Input and structured output

Input includes `hook_event_name`, `cwd`, session/turn/agent identifiers, model,
permission mode (`ask`, `auto`, `all`), and a nullable `transcript_path`. Tool
events carry `tool_name`, `tool_input`, and tool-call identifiers as both
`tool_call_id` and `tool_use_id`. Post-tool input carries `tool_response` as a
synth result string. Required empty fields remain present. Completion input
includes `stop_hook_active` and nullable `last_assistant_message`. Compaction
has `trigger: "manual"` or `"auto"`; session starts have `source`. Model events
carry `request_id`, `attempt`, status, an error name when available, and token
counts. Child inputs identify the child and its parent session.

Grouped stdout must be empty or a JSON object. Unknown fields, wrong types,
mismatched event names, unsupported effects, and responses over 64 KiB fail
visibly. Stdin, stdout, and stderr are drained concurrently; each captured
output stream is bounded at 64 KiB. A truncated JSON response is never applied.
Stderr remains the blocking reason on exit 2. Other nonzero exits are advisory;
inspection records retain the exit status. Observation-only failures are
reported without acquiring policy authority.

A denial:

```json
{ "decision": "block", "reason": "Do not change credentials" }
```

A complete replacement input (not a patch):

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "ask",
    "updatedInput": { "command": "git status --short" },
    "additionalContext": "Check the working tree first."
  }
}
```

Replacement inputs must be objects satisfying the declared tool field types
and required fields. Normal tool/server validation still applies. Approvals,
project boundaries, displayed arguments, persistence, and checkpoints use the
replacement. A pre-tool `allow` never bypasses normal approval policy. A
permission hook can grant a single call:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": { "behavior": "allow" }
  }
}
```

Use `deny` and an optional `message` to refuse it. Permission hooks cannot
rewrite arguments or standing permissions. Denial wins over allowances and
rewrites. Grouped synchronous handlers see the same immutable input and all
run, even if one denies. Reporting follows declaration order; the last
completed rewrite wins. Configure one rewriting handler per tool to avoid
timing-dependent results. Legacy lists remain serial and stop on denial; this
does not suppress admitted grouped handlers.

`systemMessage` is a user-facing notice. `additionalContext` is attributed to
its hook and added as model-visible user context at a safe boundary. It does
not acquire system-prompt authority. `continue: false` with `stopReason` stops
supported transitions. On `Stop`/`SubagentStop`, `decision: "block"` requests
continuation; `continue: false` ends work instead. Unsupported control on
observation events produces a diagnostic.

A grouped post-tool block replaces only the model-visible result with feedback.
The call's effective arguments and successful/failed status remain, and the
original result is retained in SQLite as `hook_original_tool_result`. For MCP
tools, `updatedMCPToolOutput` can supply replacement model-visible output.
Neither form rolls back an executed tool. Legacy post-hook exits keep their
previous advisory behavior.

## Concurrency and background work

The runtime admits at most eight hook handlers concurrently across the session,
parallel tool calls, and children. Waiting for admission does not consume an
execution timeout, and cancellation prevents queued commands from launching.
Grouped synchronous dispatch overlaps admitted handlers; legacy lists run one
at a time through the same admission bound.

Only commands support `async: true`. Background work belongs to the session,
not the tool batch. Results wait for the next safe model boundary; idle
completion does not start a turn. Denial, rewriting, permission, continuation,
and output replacement from background hooks have no control authority and
produce a diagnostic. Shutdown cancels and joins background jobs and discards
undelivered context. The background backlog applies backpressure at 64 jobs. Grouped synchronous
dispatch also bounds pending results at 64 while starting queued work as slots
free. Context is bounded and spilled rather than accumulated indefinitely in
memory.

## MCP handlers

```json
{
  "hooks": {
    "PreToolUse": [{
      "matcher": "^Bash$",
      "hooks": [{
        "type": "mcp_tool",
        "server": "policy",
        "tool": "check",
        "arguments": {
          "input": "${tool_input}",
          "label": "checking ${tool_name}"
        },
        "timeout_ms": 2000
      }]
    }]
  }
}
```

A full `${field.nested}` placeholder preserves its JSON type; a placeholder
inside a larger string becomes text. Expansion recurses through objects and
arrays and missing fields fail visibly. The expanded MCP arguments must be an
object. Hooks call an already-connected MCP
tool directly: they never reconnect a server, recursively invoke hooks, or ask
a second agent approval. They use the shorter hook/tool deadline and retain
the client's cancellation and elicitation handling. MCP output passes through
the same parser, retains external-tool attribution, and obeys the same trust
gate. Missing connections and malformed pre-operation results fail closed.
MCP hooks require discovery to have settled and the tool to be installed;
readiness failures are visible, including at startup. Calls share the existing
connection lock with ordinary tools and check cancellation/deadlines while
waiting. The current MCP client declines server-initiated requests (including
elicitation) and reports `input_required` as unsupported; hooks preserve that
behavior and do not introduce a second waiting UI. MCP hooks are synchronous
and unavailable for `SessionEnd`.

## Private output and transcripts

Model-visible hook text over 8 KiB is preserved in an owner-only temporary file
with a bounded preview and path. Files live in a private session temporary
directory and are removed on shutdown. Payloads are not copied into diagnostic
records; inspection keeps bounded ids, timing, status, exit codes, and error
names. This is separate from a hook script's own choice to log its input.

Set `transcript: true` on a handler to request a private JSONL snapshot. The
format is unstable: each line describes an available conversation message,
its sequence, role, text, and tool calls. In-memory previews remain previews;
`result_bytes` identifies shortened results. Tool post-hooks receive the batch's
immutable pre-execution snapshot plus their current `tool_response`. Model
attempt hooks receive the request's immutable history snapshot. When a snapshot
is not available, `transcript_path` is null, never the SQLite database path.

## Compatibility checks and deliberate differences

The checked-in [input](../src/core/fixtures/hooks/inputs.json) and
[result fixtures](../src/core/fixtures/hooks/results.json)
are derived from the Codex contract pinned in the
[parity plan](hooks-parity-plan.md). Tests cover the shared parser and observable
loop effects, including persistence, denial, rewritten checkpoints, lifecycle
ordering, concurrency, and background delivery.

Synth keeps its canonical tool arguments and string tool results, its stricter
pre-operation error handling, exact legacy matchers, legacy ignored stdout,
30-second default, and project-root execution. Grouped definitions opt into
new post-tool controls. Regex syntax is synth's documented subset. Prompt and
agent handler types are rejected. There are no fork events without session
forks. Enterprise policy distribution, plugin installation/content verification,
remote executors, Windows support, and code mode remain platform differences;
local hook support does not imply full Codex platform parity.

## Examples

The repository includes `examples/hooks/log-event.sh`, a dependency-free hook
that appends the timestamp and input JSON for each event to
`.synth-hooks.log`. Add this block to the checkout's `config.json`:

```json
{
  "think": true,
  "hooks": {
    "UserPromptSubmit": [
      { "command": "./examples/hooks/log-event.sh" }
    ],
    "PreToolUse": [
      { "command": "./examples/hooks/log-event.sh" }
    ],
    "PostToolUse": [
      { "command": "./examples/hooks/log-event.sh" }
    ]
  }
}
```

Start synth, review and trust the declarations through `/hooks`, then submit a
prompt and inspect the log from another terminal:

```sh
tail -f .synth-hooks.log
```

`UserPromptSubmit` appears for every prompt. The pre- and post-tool entries
appear when the model calls a tool. The log is covered by the repository's
`*.log` ignore rule.

`examples/hooks/` holds five, each usable as it stands and meant to be edited
into whatever the project actually needs.

| Hook | Event | Needs | What it does |
| --- | --- | --- | --- |
| `deny-command.sh` | `PreToolUse`, matcher `bash` | `jq` | Refuses force-pushes, `reset --hard`, `terraform apply`, cluster deletes, package publishes, and recursive deletes above the checkout. |
| `protect-paths.sh` | `PreToolUse`, matchers `edit` and `write` | `jq`, `python3` | Refuses `.env`, lockfiles, CI config, applied migrations and private keys. |
| `format-after-edit.sh` | `PostToolUse`, matchers `edit` and `write` | `zig` | Runs `zig fmt` so the model does not spend turns on whitespace. |
| `block-secrets.sh` | `UserPromptSubmit` | none | Refuses a prompt carrying what looks like a live credential. |

`deny-command.sh` and `protect-paths.sh` decide *never*, which is the part
`auto_approve_safe_commands` cannot express: that setting chooses between
running a command and asking about it, and a hook is what removes the option.

`block-secrets.sh` is the counterpart to the redaction synth already applies to
tool output: that covers a key on the way out of a tool, this covers one pasted
in on the way to the model.

Both `jq` hooks exit 0 when `jq` is missing, so a checkout without it allows
rather than blocks. Decide whether that is the tradeoff you want before relying
on either as policy.

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "command": "./examples/hooks/block-secrets.sh" }
    ],
    "PreToolUse": [
      { "matcher": "bash", "command": "./examples/hooks/deny-command.sh" },
      { "matcher": "edit", "command": "./examples/hooks/protect-paths.sh" },
      { "matcher": "write", "command": "./examples/hooks/protect-paths.sh" }
    ],
    "PostToolUse": [
      { "matcher": "edit", "command": "./examples/hooks/format-after-edit.sh" },
      { "matcher": "write", "command": "./examples/hooks/format-after-edit.sh" }
    ]
  }
}
```
