# Hooks

Hooks run trusted local commands or already-connected MCP tools at agent lifecycle
boundaries. The TUI, ACP, headless mode, and task subagents share the runtime.
Commands run from the session working directory and receive one JSON object on
stdin. The initial working directory is the project root.

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
changes to the main config take effect on restart. A trusted current
`ConfigChange` policy can reject replacement hook definitions before adoption.

Flat definitions retain legacy behavior: exact tool matchers, serial execution,
ignored stdout, and advisory post-tool exits. Exiting 2 blocks prompt/pre-tool
operations, including when stderr is empty. Execution failures before an
operation fail closed. The default timeout remains 30 seconds, and the initial working
directory remains the project root. An explicit session directory change also
changes the working directory for subsequent hook commands.

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
only synchronous command handlers. `MessageDisplay` defaults to ten seconds
unless the shared default or handler timeout is overridden.

For grouped tool events, `*` or an empty matcher selects every tool. Otherwise
the matcher is a regex over the canonical name or its alias: `bash`/`Bash`,
`read`/`Read`, `write`/`Write`, `edit`/`Edit`, and `task`/`Agent`. A matching alias
does not cause a second invocation. Payload tool names remain synth's canonical
names. Non-tool matchers select these fields (flat definitions compare exactly;
grouped definitions use regex):

| Events | Matcher field |
| --- | --- |
| `SessionStart`, `ConfigChange`, `DirectoryAdded` | `source` |
| `SessionEnd` | `reason` |
| `Notification` | `notification_type` |
| `SubagentStart`, `SubagentStop` | `agent_type` |
| `PreCompact`, `PostCompact` | `trigger` |
| `InstructionsLoaded` | `load_reason` |
| `PreModelSwitch`, `PostModelSwitch` | `to_model` |
| `StopFailure` | `error_type` |

`FileChanged` has a different matcher: literal project-root filenames separated
by `|`, such as `package.json|bun.lock`. Paths containing `/` or `\` are rejected;
there are no globs or dynamic watch paths. Other events ignore their matcher.
Supported regex syntax is literals,
`.`, character classes, anchors, groups, alternation, `\d`, `\w`, `\s` and their
negations, word boundaries, and greedy/lazy `* + ? {n,m}`. Backreferences,
lookaround, special groups, and other alphabetic escapes are rejected. Resource
exhaustion is a visible policy failure. Each match owns its scratch memory;
Rust-regex language compatibility is not implied.

## Targeted routing

Add an optional `when` object to a grouped declaration or a flat legacy entry.
All supplied fields must match exactly, in addition to the event's normal
`matcher`. Omitted fields match every value; multiple groups provide alternatives.
These selectors are case-sensitive strings, not regex or glob patterns:

| Selector | Values |
| --- | --- |
| `agent_scope` | `main`, `subagent` |
| `request_purpose` | `agent`, `approval_judge`, `compaction` |
| `agent_type` | The agent role, such as `build`, `plan`, `review`, `task` |
| `model` | Exact model id reported in hook input |
| `provider` | Exact provider name reported in hook input |

For example, route a child agent's reads to its own policy and observe approval
judge requests separately:

```json
{
  "hooks": {
    "PreToolUse": [{
      "matcher": "^Read$",
      "when": { "agent_scope": "subagent", "agent_type": "task" },
      "hooks": [{ "command": "/absolute/path/child-read-policy.sh" }]
    }],
    "PreModelRequest": [{
      "when": { "request_purpose": "approval_judge" },
      "hooks": [{ "command": "/absolute/path/observe-judge.sh" }]
    }]
  }
}
```

To narrow a group to a particular local configuration, add `"model": "qwen3"`
and the actual `provider` value from hook input to its `when` object. Synth does
not infer trust or whether an endpoint is local from a provider/model name.
Keep mandatory security policies unconditional; use routing to add specialized
rules rather than making a model label a security boundary.

Synth supplies the routing metadata. Fields placed in model-generated tool
arguments cannot change the agent scope, purpose, provider, or parent identity.
Children inherit the parent's hook set and shared runtime; `when` can select
child operations without relying on the model to call a policy tool. Filters
run before handler admission for serial, grouped, background, and MCP handlers.
They do not change the handler's existing authority: use synchronous policy
hooks such as `PreToolUse` for enforcement. `PreModelRequest` and
`PostModelRequest` remain observational and cannot veto inference.

`request_purpose` is `approval_judge` for both automatic approval stages and their
`PermissionDenied` event, `compaction` for compaction requests and the
`PreCompact`/`PostCompact` events, and `agent` otherwise. Retried model attempts
keep the same scope and purpose. Each provider attempt reports the actual
selected model; `request_id` and `attempt` pair the before/after events.
Compaction and approval requests do not emit `MessageDisplay`.

Every child input includes `parent_agent_id` and `parent_tool_call_id` alongside
`parent_session_id`, allowing tool/model events to be traced back to the
parent's delegation. Main-agent inputs leave parent ids empty. `agent_id`
identifies the current agent, and `agent_type` identifies its role.

Empty filters, null/empty selectors, unknown keys, invalid scopes/purposes, and
non-string selectors are configuration errors. Put a grouped filter beside
`matcher` and `hooks`, not inside individual handlers. Listing/review show the
filter; recent records show scope and purpose. Adding or changing a filter
changes the declaration's trust id and requires review. Existing declarations
without `when` retain their previous ids and behavior.

## Events and effects

| Event | When it runs | Supported control |
| --- | --- | --- |
| `SessionStart` | Before the first request after startup, resume, clear, or successful compaction | Context or stop |
| `SessionEnd` | Main-session shutdown, clear, or switching to a saved session | Diagnostics only |
| `UserPromptSubmit` | New prompts and steering, before persistence | Denial or context |
| `UserPromptExpansion` | An ACP skill command expands, before submission | Denial |
| `PreToolUse` | Every admitted tool identity, before approval and checkpoints | Denial, context, replacement arguments, or request approval |
| `PermissionRequest` | A call otherwise needs an approval decision | Allow once, deny, or leave normal flow in force |
| `PermissionDenied` | The automatic approval judge denies a call | Retry advice; never grants approval |
| `PostToolUse` | A successful tool result | Feedback or context; side effects remain |
| `PostToolUseFailure` | An executed tool returns an error | Context and diagnostics |
| `PostToolBatch` | All calls in an assistant message have results, including owner answers and rejected calls | Context or stop before the next request |
| `TaskCreated` | A normalized todo item would be added | Deny the proposed todo update |
| `TaskCompleted` | A todo item would first enter `done` | Deny the proposed todo update |
| `PreCompact` | Before manual or automatic compaction | Stop while preserving history |
| `PostCompact` | After successful compaction | Stop automatic resumption |
| `SubagentStart` | Child startup | Context and diagnostics; cannot deny creation |
| `SubagentStop` | Child completion, before its parent receives the answer | Request more child work |
| `Stop` | Normal root-turn completion | Request more work within the existing budgets |
| `StopFailure` | A normal agent request ends with an API/provider error | Diagnostics only; finishes before the failed turn closes |
| `Notification` | Notices, approval/input waits, turn completion, authentication, or an idle reminder | Diagnostics only |
| `InstructionsLoaded` | A project instruction file is actually loaded into the system-prompt cache | Diagnostics only |
| `ConfigChange` | A watched config/skill file changes; also before adopting changed hook definitions | Stop the next request or reject hook-definition adoption |
| `CwdChanged` | `/cd`, the agent `cd` tool, or ACP changes the session working directory | Diagnostics only |
| `DirectoryAdded` | `/add-dir` or ACP registers an additional permitted root | Diagnostics only |
| `FileChanged` | A configured file is added, changed, or removed, including external writes | Diagnostics only |
| `PreModelSwitch` | Before an explicit model selection changes the provider | Deny the switch |
| `PostModelSwitch` | The actual model changes, including automatic selection or session restoration | Diagnostics only |
| `MessageDisplay` | Assistant text is about to be displayed | Replace display text only |
| `Interrupt` | Explicit cancellation of a busy root turn, once | Diagnostics only |
| `PreModelRequest` | Each actual request attempt, including retries, classification, and compaction | Diagnostics only |
| `PostModelRequest` | Exactly once per attempt, completed/failed/cancelled | Diagnostics and available usage |

Session-start hooks are deferred until a prompt needs the session. Cancelling
or a failed/blocked start does not admit that prompt. Completion continuations
set `stop_hook_active`, carry an attributed reason, and retain the original
turn's time, token, and step limits. Cancellation does not invoke completion
hooks. Child shutdown does not emit main-session `SessionEnd`. Clear and resume
cancel old background work and discard its undelivered context before switching
logical sessions. `SessionEnd.reason` is `shutdown`, `clear`, or `resume`.

Grouped `PostToolUse` is success-only. Flat legacy post-tool definitions still
receive both success and failure, with their previous ignored-stdout behavior.
A denied call was never executed and does not emit `PostToolUseFailure`.
`PermissionDenied` covers the automatic judge, not manual or pre-hook denials.
`retry: true` adds advice for a new attempt; the rejected call remains rejected.
`StopFailure` is separate from normal `Stop`, cancellation, budget exhaustion,
and a failed classifier that falls back to asking the user.

Todo hooks compare the normalized proposed list with the current list. Stable
`task_id` values are SHA-256 hashes of normalized task text. All item policies
must pass before the entire list changes; denial leaves the old list intact.
Removing a task does not mark it completed. `continue: false` is ignored for
these two events; use `decision: "block"` or exit 2 to reject an update.

`CwdChanged` includes `old_cwd` and `new_cwd`; the common `cwd` is the new
directory. It fires only after a successful actual change. `DirectoryAdded`
includes `directory` and `source` (`slash_command` or `register_repo_root`) and
fires after updating the file-access boundary. Adding an already-covered path,
an invalid path, or a busy-session request emits neither event. The two events
have no blocking authority. See [Session directories](usage.md#session-directories)
for commands and the shell-subprocess distinction.

File watchers poll metadata at most once a second, also checking before model
requests. Fast writes may coalesce. Config watches cover the loaded main config,
user/project hook files, and discovered skill files. An idle change never starts
a model turn. Watching does not add automatic main-config or skill reloading;
the normal restart/reload rules still apply. Instructions hooks describe actual
instruction loads, not arbitrary reads of `AGENTS.md` or `CLAUDE.md`.

Notification types are `notice`, `permission_prompt`, `agent_needs_input`,
`agent_completed`, `idle_prompt` (once after 60 idle seconds), and `auth_success`
(ACP authentication). Notices delivered from hook results do not recursively emit notifications.
Observation events run as session-owned background work except `StopFailure`,
model request attempt hooks, and `MessageDisplay`, which complete synchronously
with their owning operation.

## Input and structured output

Input includes `hook_event_name`, `cwd`, session/turn/agent identifiers, model,
provider, `agent_scope`, `request_purpose`, parent agent/delegation ids,
permission mode (`ask`, `auto`, `all`), and a nullable `transcript_path`. Tool
events carry `tool_name`, `tool_input`, and tool-call identifiers as both
`tool_call_id` and `tool_use_id`. Post-tool input carries `tool_response` as a
synth result string. Required empty fields remain present. Completion input
includes `stop_hook_active` and nullable `last_assistant_message`. Compaction
has `trigger: "manual"` or `"auto"`; session starts have `source`. Model events
carry `request_id`, `attempt`, status, an error name when available, and token
counts. Child inputs identify the child and its parent session.

New event-specific fields include:

| Events | Fields |
| --- | --- |
| `PostToolUseFailure` | `error`, `error_message`, `is_interrupt`, `duration_ms`, plus normal tool fields |
| `PostToolBatch` | `tool_calls`: array of effective tool names, ids, parsed inputs, model-visible responses, and statuses |
| `PermissionDenied` | Tool fields and denial reason in `error_message` |
| `StopFailure` | `error_type`, `error`, `error_details`, `last_assistant_message` |
| `Notification` | `notification_type`, `message`, `title` |
| `InstructionsLoaded` | `file_path`, `load_reason`, `memory_type` |
| `ConfigChange` | `source`, `file_path` |
| `CwdChanged` | `old_cwd`, `new_cwd` |
| `DirectoryAdded` | `directory`, `source` |
| `FileChanged` | `file_path`, `event` (`add`, `change`, `unlink`) |
| Model switches | `from_model`, `to_model`, `source`, optional `requested_model` |
| Task events | `task_id`, `task_subject`, `task_description` |
| `UserPromptExpansion` | `command_name`, `command_args`, `expanded_prompt` |
| `MessageDisplay` | Stable `message_id`, zero-based `index`, `delta`, `final` |

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

## Display transformations

`MessageDisplay` applies only to ordinary assistant answers, not internal
classification or compaction. TUI/ACP streaming batches complete lines, followed
by a final batch (possibly empty). Headless mode emits one final whole-message
batch. Return a replacement for that batch:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "MessageDisplay",
    "displayContent": "Text to show"
  }
}
```

The provider reply, future model context, and SQLite retain the original text.
The replacement is transient: resuming a saved session displays the original.
Timeouts and malformed output fail open to the original display text. This is
a presentation feature, not a persistent redaction boundary.

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
loop effects, including the [Claude Code trigger expansion](claude-hooks-trigger-parity.md),
persistence, denial, rewritten checkpoints, lifecycle
ordering, concurrency, and background delivery.

Synth keeps its canonical tool arguments and string tool results, its stricter
pre-operation error handling, exact legacy matchers, legacy ignored stdout,
30-second default, and initial project-root execution. Hook commands follow
explicit session directory changes; use absolute script paths when hooks must
keep referring to the original checkout. Grouped definitions opt into
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

## Model request customization

Four synchronous stages customize requests for main agents and subagents. Their
`when` filters use the same agent identity and `request_purpose` as tool hooks.
Existing `PreModelRequest` and `PostModelRequest` remain observations of actual
transport attempts, including retries.

| Event | Timing | Allowed `hookSpecificOutput` |
| --- | --- | --- |
| `ModelResolve` | Once before preparing a request | `route`: a configured route id |
| `ModelSettings` | After selecting the route | `settings`: supported generation and retry settings |
| `ModelContext` | After settings, before serialization | `contextEdits`: `[{"seq":42,"text":"replacement"}]` |
| `ModelRetry` | Before a retryable, unstreamed failure is retried | `retryAllowed`: boolean; `retryDelayMs`: 0–60000 |

For example, an approved policy handler can respond with:

```json
{"hookSpecificOutput":{"hookEventName":"ModelResolve","route":"local-review"}}
```

Routes are declared in `model_requests`, not in handler output. A route fixes the
provider protocol, endpoint, model, credentials, and allowed purposes. Unknown
routes and disallowed purposes fail before transport. Selecting a route never
changes the session's selected model. `restrict_routes: true` requires a named
route for all three purposes and prevents falling back to the active provider.
Explicit routes support Ollama and OpenAI-compatible endpoints. A new endpoint
receives only that route's explicit credential; it never inherits the active
provider's key. OpenAI-compatible redirects are refused.

`settings` accepts `temperature` (0–2), `max_output_tokens` (1–1048576),
`reasoning_effort` (a level supported by the selected backend/model), `attempts`
(1–4 total attempts), and `retry_delay_ms` (0–60000). Unsupported generation
settings fail before sending; ChatGPT and Copilot routes reject temperature and
output-token overrides. Ollama maps output limits to `num_predict`;
OpenAI-compatible Chat, Responses, and Messages requests use their respective
output-token fields. Each selected provider enforces its own context budget.

`request_context` contains a JSON-encoded transcript with stable message sequence
numbers and provenance. Edits change a request-owned copy and mark edited text as
hook-originated. They cannot change stored history, tool arguments, message roles,
or approval evidence. Approval reviewer context is immutable: an attempted edit
makes review unavailable and follows the configured fallback. `request_settings`
contains the prepared settings, and `route` names the selected route. Retry input
also contains the current attempt, proposed delay, and `retry_allowed`.

Retry hooks may cancel a retry or adjust its delay. The provider retains control
of retry eligibility: no retry after streaming, no retry of permanent refusals,
and no override of its attempt ceiling. These four stages reject asynchronous
handlers; errors prevent that request or retry from proceeding.

## Authorization provenance and execution evidence

Human prompts, agent delegation, hook context, tool results, and harness messages
have distinct origins. Origins are stored in SQLite and carried over ACP. Older
rows without provenance remain `unknown`. Automatic review uses a separate bounded
journal of verified human requests, choices, and answers, including across
compaction and resume. Hook output and summaries never become human authority.
If no verified human request is available, review uses the configured fallback.

Each tool action is prepared after validating its input. The prepared evidence
contains the call id, tool, effective arguments, canonical cwd, permitted roots,
resolved `path`/`file` targets, agent identity, and parent delegation identity.
Approvals bind to that evidence. A rewrite is validated and prepared again before
approval. Changed arguments, cwd, roots, or symlink targets invalidate approval;
workers check the snapshot again before invoking a tool. Approved evidence is
saved as an `approved_action` blob. TUI approval panels show the cwd and resolved
targets, and ACP exposes prepared and approved snapshots.

Background handlers share session concurrency limits, but their context goes only
to the launching agent. Closing that agent cancels and discards its pending
background deliveries. Diagnostics remain visible at session scope.

These checks are harness policy, not an OS sandbox. Shell commands and trusted
hook commands still run with the process's permissions. Filesystem checks cannot
make a path immutable against another process changing it between checking and
opening it.
