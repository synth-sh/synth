# Codex hooks audit and synth parity plan

Bring synth to functional parity with Codex's local lifecycle hooks while keeping existing hook scripts usable. Start by closing execution gaps, then add structured results, lifecycle coverage, trust, background execution, MCP handlers, and inspection. Keep one hook runtime shared by the TUI, headless mode, ACP, and subagents.

The local runtime implementation is documented in [Hooks](hooks.md). The audit
baseline and original acceptance criteria below are retained for review.

## Baseline and scope

- synth source: `101872ff107086f2a9914a9d34e285f6ff80b9aa`.
- Codex source: local checkout `/Users/boeschj/Documents/GitHub/codex`, commit `01806453b03b18388afa90920ba3778f66b02fa6`. Source links below are pinned to that commit.
- Installed Codex CLI: `0.167.2`. The checkout is the implementation reference; it was not verified to match that release exactly.
- Product reference: [official hook guide](https://learn.chatgpt.com/docs/hooks), checked on November 13, 2026.
- Expected load: one local session, up to eight parallel tool calls, with nested read-only agents. Hook concurrency must also have a session-wide bound.

Parity means equivalent capabilities and event behavior for synth's local execution paths. It does not mean that a Codex script can assume Codex tool arguments inside synth. Preserve synth's canonical tool names and payloads; document matcher aliases and argument differences.

Enterprise policy distribution, plugin installation, remote executors, Windows support, and code mode require product infrastructure outside this hook upgrade. Track those as explicit remaining differences. Do not call this complete Codex platform parity.

## What Codex does

| Area | Codex implementation | synth today |
| --- | --- | --- |
| Lifecycle | Fourteen named events, including sessions, subagents, compaction, completion, interruption, and model attempts. | Three events: prompt submission and pre/post tool use. |
| Contract | Typed event inputs and outputs, schema fixtures, session/turn/tool identifiers, and event-specific control effects. | A small shared input record; blocking reason or error is the only dispatch result. |
| Tool policy | Pre-tool denial, additional context, and replacement input; a separate permission-request decision. | Exit 2 can block an already-approved tool call. |
| Post-tool behavior | Can replace model-visible output with feedback after execution. Cannot undo the tool. | Output and errors from post hooks are discarded. |
| Dispatch | Matching synchronous handlers run concurrently. Results are reported in declaration order. A denial wins; competing pre-tool rewrites use completion order. | Sequential execution stops at the first blocking hook. |
| Background work | Command hooks can run asynchronously; eight execute concurrently per session. Results are delivered at safe conversation boundaries. | Prompt hooks run off the UI thread, but still gate the operation. There is no background hook lifecycle. |
| Discovery and trust | Hook files and inline config are additive across sources. Non-managed declarations need trust for their current hash. Plugins also have content verification. | Hooks come from the loaded config. There is no hook-specific trust or inspection. |
| Handlers | Commands and already-connected MCP tools. Prompt and agent handlers are recognized but skipped. | Commands only. |
| Visibility | Started/completed records, source, status, timing, diagnostics, and hook inspection. Model-visible oversized context is saved to disk with a preview. | Prompt notices and pre-tool failure strings; limited stderr capture. |

Implementation evidence:

- [Event registry and supported names](https://github.com/openai/codex/blob/01806453b03b18388afa90920ba3778f66b02fa6/codex-rs/hooks/src/lib.rs).
- [Typed schemas](https://github.com/openai/codex/blob/01806453b03b18388afa90920ba3778f66b02fa6/codex-rs/hooks/src/schema.rs), [output parser](https://github.com/openai/codex/blob/01806453b03b18388afa90920ba3778f66b02fa6/codex-rs/hooks/src/engine/output_parser.rs), and [pre-tool result reduction](https://github.com/openai/codex/blob/01806453b03b18388afa90920ba3778f66b02fa6/codex-rs/hooks/src/events/pre_tool_use.rs).
- [Concurrent dispatcher](https://github.com/openai/codex/blob/01806453b03b18388afa90920ba3778f66b02fa6/codex-rs/hooks/src/engine/dispatcher.rs), [command runtime](https://github.com/openai/codex/blob/01806453b03b18388afa90920ba3778f66b02fa6/codex-rs/hooks/src/engine/command_runner.rs), and [process lifecycle tests](https://github.com/openai/codex/blob/01806453b03b18388afa90920ba3778f66b02fa6/codex-rs/hooks/src/engine/command_runner_tests.rs).
- [Discovery and trust admission](https://github.com/openai/codex/blob/01806453b03b18388afa90920ba3778f66b02fa6/codex-rs/hooks/src/engine/discovery.rs), [MCP execution](https://github.com/openai/codex/blob/01806453b03b18388afa90920ba3778f66b02fa6/codex-rs/hooks/src/engine/mcp_runner.rs), and [output spill](https://github.com/openai/codex/blob/01806453b03b18388afa90920ba3778f66b02fa6/codex-rs/hooks/src/output_spill.rs).
- [Core integration](https://github.com/openai/codex/blob/01806453b03b18388afa90920ba3778f66b02fa6/codex-rs/core/src/hook_runtime.rs), [tool integration and rewritten inputs](https://github.com/openai/codex/blob/01806453b03b18388afa90920ba3778f66b02fa6/codex-rs/core/src/tools/registry.rs), and [canonical names versus aliases](https://github.com/openai/codex/blob/01806453b03b18388afa90920ba3778f66b02fa6/codex-rs/core/src/tools/hook_names.rs).

## Lessons and deliberate differences

Adopt Codex's separation between running a handler, interpreting its event-specific result, and applying that result in the agent loop. A process exit code alone cannot represent permission decisions, input changes, completion checks, and logging.

Keep these distinctions visible during implementation:

- Off-thread blocking work and a background hook are different. Only synchronous handlers can deny, approve, rewrite, or request continuation.
- Trust authorizes a hook definition to execute. It does not make an arbitrary referenced shell script immutable, sandbox the hook, or make shell pattern matching a complete security boundary. Codex's plugin content checks are stronger than its ordinary declaration trust.
- Codex reports many execution/parser failures and continues. Its pre-tool and prompt handlers also require nonempty stderr to block on exit 2. Preserve synth's stronger existing behavior: pre-operation execution failures stop that operation, and exit 2 without a reason still blocks with a generic reason. Make invalid structured policy output fail that operation too. Observation-only hook failures remain diagnostic.
- Codex's last-completed rewrite rule is timing-dependent. Implement it for grouped definitions and test it explicitly; tell users to configure only one rewriting handler per tool. Denial always overrides rewrites and approvals.
- Keep synth's existing 30-second timeout default and project-root working directory. Add per-handler timeouts; do not silently adopt Codex's 600-second default or session-directory behavior.
- Preserve flat definitions as legacy behavior: serial execution, ignored stdout, existing post-hook semantics, and exact matchers. New grouped definitions opt into structured results, richer matchers, and concurrent dispatch. Normalize both into one runtime with an explicit legacy mode; do not build two engines or automatically rewrite user config.

## Implementation sequence

Each numbered item is a reviewable change with its own tests and documentation. Later items depend on the shared contracts established earlier.

### 1. Close current execution gaps

Touch [hooks.zig](../src/core/hooks.zig), [loop.zig](../src/agent/loop.zig), [subagent.zig](../src/agent/subagent.zig), [tool_run.zig](../src/agent/tool_run.zig), and [protect-paths.sh](../examples/hooks/protect-paths.sh).

- Keep timeout and cancellation active until the child is reaped, even when stdin and stderr have closed. Retain process-group cleanup on timeout or cancellation.
- Pass the tool batch's stop signal into hook execution; check cancellation again before executing a tool after its pre-hook.
- Run prompt checks before accepting steering into the transcript. Preserve asynchronous UI behavior and prevent a checked queued message from being checked twice when promoted to a new turn.
- Inherit hooks in task subagents and surface child hook failures to the parent.
- Cover loop-handled `todo` and `ask_user` calls, which currently bypass `ToolRun`. Run pre-hooks before changing todos or showing a question, and post-hooks once their result exists. Keep owner-thread state changes on the owner thread.
- Normalize protected paths, including absolute paths, `.`/`..`, and existing symlink targets, before applying the example policy. Preserve the script's documented behavior when `jq` is missing.

Acceptance: regression tests cover steering rejection, denied subagent reads, todo/question policies, cancellation during a pre-hook, descendant cleanup, and equivalent protected paths. A hook that redirects stderr and sleeps must time out; the review reproduction took 511 ms with a 50 ms limit and returned success.

### 2. Establish typed contracts and bounded output

Touch the hook module, [config.zig](../src/core/config.zig), [config.schema.json](../config.schema.json), [conversation.zig](../src/core/conversation.zig), and [context.zig](../src/agent/context.zig). Split the hook module by responsibility only where the new code requires it.

- Add event-specific input/result types and checked-in JSON fixtures. Include session, turn, tool-call, and child identifiers, model, permission mode, and required empty fields. Use `transcript_path: null` until a real transcript export exists; never substitute the SQLite database path.
- Capture stdout and stderr concurrently with stdin. Bound memory, continue draining full pipes, and report oversized structured responses as failures instead of interpreting partial JSON.
- Parse structured results for grouped definitions: block/reason, system messages, additional context, replacement input, permission decisions, and stop continuation. Validate field types and event names; unsupported effects must be reported rather than silently applied.
- Attribute injected context to its hook source. MCP hook text must retain external-tool provenance rather than silently acquiring trusted configuration authority.
- Bound model-visible context and preserve oversized text in a private temporary file with a preview. Reuse existing truncation helpers where they fit. Keep sensitive payloads out of diagnostic logs by default.
- Validate timeout ranges and integer conversion at config load.

Acceptance: fixture tests cover empty payloads, escaping, invalid JSON/types/events, every supported output form, output limits, and legacy stdout remaining ignored. Blocked prompt text must not enter persistent conversation history.

### 3. Apply policy before approvals and checkpoints

Touch the loop's approval and tool scheduling paths, tool execution, and file checkpoint handling.

The execution order becomes: validate tool identity and agent access; run synchronous pre-tool hooks; validate replacement arguments; evaluate normal project boundaries and approvals; run `PermissionRequest` only when an approval is needed; checkpoint the effective paths; execute; process post-tool results.

- Run pre-tool hooks once per invocation, before any model judge or approval prompt. Move the existing invocation out of the execution worker so it cannot run a second time.
- A replacement is a complete validated input, not a patch merged into stale arguments. Clear any approval assessment derived from the original input and update the displayed/executed call consistently.
- Aggregate results conservatively: any denial wins; a pre-tool `allow` permits a rewrite but does not itself bypass normal approvals. A `PermissionRequest` allow is a one-call decision, never a persisted standing allowance.
- Preserve the tool's actual side effects when post-hooks reject its result. Record what ran, replace only model-visible output with feedback, and retain normal error results and diagnostics.
- Keep policy checks shared across ordinary tools, owner-thread tools, MCP calls, and subagents.

Acceptance: a harmless command rewritten into a destructive command needs fresh approval; a rewritten file path gets the correct boundary check and checkpoint. Denial beats allow/rewrite. All approval modes still honor pre-tool denial. A post-hook rejection cannot hide which command actually executed.

### 4. Add discovery, richer matching, and explicit trust

Touch config loading, [stack.zig](../src/agent/stack.zig), hook discovery, and user-owned trust storage.

- Accept Codex-style event → matcher group → handlers JSON alongside the existing flat format. Handler types are `command` and, once item 7 lands, `mcp_tool`. Reject unsupported handler types with actionable diagnostics.
- Load inline synth config plus user and project `.synth/hooks.json` sources additively, retaining source paths and declaration order. A project file must not replace user hooks.
- Add wildcard, alternation, and regex matching for grouped definitions. Ignore matchers on events that do not support them. Add `Bash`, `Read`, `Write`, `Edit`, and `Agent` matcher aliases while retaining synth's actual payload names and avoiding duplicate invocation.
- Reuse [regex.zig](../src/core/regex.zig) only with safe concurrent scratch ownership and visible resource-limit failures. Its current mutable scratch and budget-exhaustion-as-no-match behavior cannot be shared unchanged by concurrent policy dispatches. Document the supported syntax and reject unsupported constructs; Rust-regex language compatibility is not implied.
- Review and trust the exact definition before any non-managed hook executes. Hash source identity, event, matcher, handler, arguments, timeout, and control-affecting settings. Changed/new definitions need review again; disabling stays separate from trust.
- Keep trust outside repository-controlled hook/config files. Reuse the existing database setting API only with private user-owned storage; debug mode's project database is not a trust store. Do not add a table or service when a private state file suffices.
- Existing hooks need a one-time trust review after upgrade. Show pending review explicitly in every frontend and headless mode; never auto-trust them as a migration side effect.

Acceptance: test additive loading, duplicate definitions, source identity, malformed config, unsupported regex, concurrent matching, trust invalidation, disable/re-enable, and moving the same declaration to another project. A model-edited hook file cannot authorize itself.

### 5. Cover the complete applicable lifecycle

Wire the fourteen events below to actual transitions. Reuse existing loop states and futures; add explicit pending transitions when asynchronous hook completion must delay an action.

| Event | Integration and result |
| --- | --- |
| `SessionStart` | Startup, resume, clear, and successful compaction. Context and stop behavior apply before the next request. Emit a fork source only if synth implements session forks. |
| `SessionEnd` | Main-session orderly shutdown, once. Short bounded synchronous cleanup; no MCP handler. |
| `UserPromptSubmit` | New prompts and steering, before transcript persistence and model use. Denial or context. |
| `PreToolUse` | Every executable local tool call, including children and owner-thread handlers. Denial, context, or validated replacement input. |
| `PermissionRequest` | Before an otherwise-required user/model approval. Allow, deny, or defer to normal flow. |
| `PostToolUse` | Completed tool results, including ordinary error outputs. Feedback/context; never rollback. |
| `PreCompact` | Before manual/automatic compaction, with the trigger. A stop preserves the existing history. |
| `PostCompact` | After successful compaction, with the trigger. A stop prevents automatic resumption. |
| `SubagentStart` | Task creation, with child identity/type. Context and diagnostics; match Codex's non-blocking start semantics. |
| `SubagentStop` | Child completion before the parent receives its final answer. Can request more child work. |
| `Stop` | Normal root-turn completion. Can request continuation with a reason. |
| `Interrupt` | Explicit interruption of a busy root turn, once. Cannot prevent cancellation or restart work. |
| `PreModelRequest` | Before every model request attempt, including retries and compaction. Diagnostic only. |
| `PostModelRequest` | Exactly once after that attempt: completed/failed/cancelled, error, and available token usage. Diagnostic only. |

Touch the loop, stack/session lifecycle in ACP, subagent runner, [request.zig](../src/agent/request.zig), [provider.zig](../src/provider/provider.zig), and provider retry loops. Instrument the actual attempt boundary; wrapping `Request.start` alone misses retries hidden inside providers. Avoid process-wide mutable hook state in providers.

Completion hooks need `stop_hook_active`, a continuation reason attributed to the originating hook, and normal cancellation/time/token limits. Never reset budgets on each synthetic continuation or run completion hooks as a replacement for cancellation. Keep session shutdown and child shutdown distinct. Use one-second defaults capped at three seconds for end/interrupt cleanup, matching Codex's bounded lifecycle behavior.

Acceptance: deterministic fake-provider event traces cover startup/resume/clear, root and child completion, interrupted work, manual/automatic/failed compaction, retry success/failure/cancellation, and a completion hook repeatedly asking for more work. Pair every emitted model pre-event with one post-event.

### 6. Add concurrent and background execution

- Run all matching grouped synchronous handlers against the same immutable event input. Start every admitted handler even when another returns a denial. Preserve declaration order in reporting and use completion order for competing rewrites.
- Enforce a session-wide process bound across all tool calls and children. Queue work without dropping invocations; queued cancellation must prevent process launch. Start an execution timeout when a queued handler is admitted.
- Add `async: true` for command handlers. Reuse the runtime's ownership, cancellation, result parsing, and queue; keep background tasks owned by the session rather than a completed tool batch.
- Deliver informational context at the next safe model boundary. Idle background completion must not start a turn. Reject/ignore control effects with a visible diagnostic.
- On shutdown, cancel and join outstanding background work and discard undelivered context. Keep `SessionEnd` synchronous. Preserve legacy serial lists through the same scheduler.

Acceptance: test concurrency bounds across parallel calls and children, queued cancellation, denial with sibling hooks, out-of-order completion, competing rewrites, background output during an active/idle turn, and shutdown without leaked processes or payload references. Output pressure must not create an unbounded in-memory result queue.

### 7. Add MCP hook handlers

Reuse [tools/mcp.zig](../src/tools/mcp.zig) and the existing MCP client. Call an already-connected tool directly through a hook executor seam; do not route through agent tool scheduling, recursively invoke hooks, or ask a second tool approval.

- Expand `${field.nested}` recursively through objects and arrays. A full-value placeholder preserves its JSON type; interpolation inside a larger string produces text. Missing fields fail visibly.
- Feed MCP results through the same event-specific parser and trust gate as commands. Preserve external provenance.
- Keep MCP hooks synchronous and honor the shorter hook/server execution deadline, with cancellation propagated to the client. Preserve the client's elicitation handling rather than adding a second waiting mechanism.
- Report unavailable servers, tools, and malformed output consistently. For synth's pre-operation events, keep the stricter fail-closed policy described above; this intentionally differs from Codex's advisory MCP execution errors.
- Reject `SessionEnd` MCP handlers and show readiness failures from startup hooks. Never start or reconnect a server as a side effect of dispatching a hook.

Acceptance: a fake MCP server covers typed interpolation, explicit denial, malformed output, missing connection, cancellation, timeout, elicitation, and proof that a hook call cannot recursively invoke itself.

### 8. Finish inspection, migration, and parity checks

Touch [headless.zig](../src/headless.zig), ACP protocol/agent/mirror updates, [tui/slash.zig](../src/tui/slash.zig), and TUI presentation. Do not expose only the TUI implementation to other clients.

- Add hook listing/review/trust/disable operations through the existing command/session interfaces, including `/hooks` in the TUI and an equivalent noninteractive CLI path. Trust changes must come from an explicit user operation.
- Show source, matcher, effective timeout, mode, trust/enable state, and recent status. Emit started/completed records with session/turn/call identity, duration, exit status, and bounded diagnostics. Match stable ids across frontends.
- Provide a real transcript export for hooks that need history, with a documented unstable transcript format and an explicit nullable path when export is unavailable. Reuse conversation/database access and existing session cleanup; export only when needed.
- Update [hooks.md](hooks.md), [configuration.md](configuration.md), [cli.md](cli.md), [usage.md](usage.md), schema, and examples. Show legacy and grouped definitions, matcher aliases, migration review, error semantics, and every deliberate Codex difference.
- Add an event/result compatibility matrix using checked-in fixtures derived from the pinned contract. Validate observable effects, not only JSON parsing. Include TUI/ACP/headless parity and SQLite persistence behavior.

Acceptance: run `zig fmt` on changed Zig files, `zig build`, and `zig build test`. Smoke-test `zig build run -- prompt`; use fake providers for hook workflows and real local scripts for process tests. Verify a representative hook configuration through headless and ACP/TUI flows. No live model is required for the acceptance suite.

## Release gate

Local lifecycle parity is complete when all fourteen applicable events, command/MCP handlers, synchronous control results, background context delivery, trust review, inspection, and migration behavior pass the shared acceptance matrix across frontends. An unsupported event or effect must produce a diagnostic, not be silently accepted as implemented.

Keep legacy serial behavior, exact matcher behavior, 30-second defaults, project-root execution, and existing empty-reason blocking in regression fixtures. Announce the one-time trust review and any new grouped post-tool control behavior. Report the remaining platform differences above alongside the narrower parity claim.

## Implementation validation map

The implementation uses one normalized hook set and runtime across Stack-backed
headless, ACP/TUI, and child loops. Existing declarations require explicit
review; platform differences in the scope section remain intentional.

| Stage | Implementation and acceptance evidence |
| --- | --- |
| 1. Execution gaps | Process reaping/deadline and descendant tests in `core/hooks.zig`; shared pre-policy cancellation, steering rejection, owner-thread tools, and child denial tests in the agent modules. The protected-path example checks lexical and resolved paths, including symlinks, and retains its missing-`jq` behavior. |
| 2. Contracts/output | Checked-in [input](../src/core/fixtures/hooks/inputs.json) and [result](../src/core/fixtures/hooks/results.json) fixtures; strict result parsing, concurrent pipe draining, overflow rejection, nullable fields, terminal cleanup, private output spill, and immutable JSONL exports. |
| 3. Policy ordering | Loop tests verify policy precedes approval, execution invokes it once, a destructive rewrite requires approval, rewritten paths drive execution/checkpoints/SQLite arguments, one-call permissions, and post-tool feedback retains side effects and original stored results. |
| 4. Discovery/trust | Additive inline/user/project sources, source-stable duplicate ids, definition/project/timeout invalidation, private trust storage, and disable/enable/revoke checks. ACP/TUI mirror integration verifies explicit review and trust, then revocation before persistence. |
| 5. Lifecycle | Event traces cover startup, resume, clear, automatic/manual/failed compaction, child startup and continuation with stable identity, bounded main shutdown, root completion budgets, and one explicit interrupt. An HTTP fake verifies each real retry attempt; cancellation checks pair the post event and prevent a provider call after a cancelled pre-event. |
| 6. Concurrency/background | Cross-dispatch admission tests enforce eight handlers; queued cancellation prevents launch. Tests cover denial with siblings, completion-ordered rewrites beyond eight handlers, declaration-ordered diagnostics, private spill, safe idle context delivery, and shutdown joining active background commands. Pending results apply bounded backpressure. |
| 7. MCP handlers | Recursive typed interpolation and missing-field fixtures, plus a fake MCP server through the connected-call seam: denial, external provenance, unavailable connections, timeout, and no recursive scheduling. Ordinary tools and hooks serialize access to each MCP connection. A server-initiated elicitation request is declined through the existing client handling before the call settles; hooks do not add a second waiting mechanism. |
| 8. Frontends/docs | CLI `hooks` operations, shared `_synth/hooks` ACP operations, `/hooks` in the TUI, status inspection, schema, migration/reference docs, and examples. The built CLI is exercised with an isolated local fake model; no live model is needed. |

The event fixtures cover all fourteen names. Observable effects are exercised
by the loop, runtime, MCP, and ACP mirror tests rather than inferred only from
successful JSON parsing. Transcript snapshots contain the available in-memory
history, including explicit result preview lengths; they never expose the
SQLite path as a transcript. See [Hooks](hooks.md) for payload differences,
regex syntax, output semantics, and the one-time trust review.

## Implementation validation

After implementation, `zig build test` passed 941 tests with 6 skipped across
synth and MCP (836/5 and 105/1 respectively). `zig build`, the network-free
`zig build run -- prompt`, formatting, and JSON syntax checks passed. A built
CLI smoke test used an isolated local fake model to verify review/trust,
pending-review rejection before persistence, hook denial with and without
`--allow`, and SQLite results. Live providers and an interactive TUI session
were not exercised; ACP/TUI behavior is covered by the shared mirror tests.

## Validation of this audit

`zig build test` passed again after creating this plan: 872 tests passed and 6 were skipped across synth and MCP. Repository links and the fourteen-event checklist were checked. The preceding review reproduced the timeout failure in a temporary copy of the hook module and equivalent-path bypasses by invoking the example script with JSON payloads. Codex's implementation and relevant tests were inspected; its Rust suite and live provider sessions were not run.
