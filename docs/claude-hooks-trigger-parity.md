# Claude Code hook trigger coverage

Synth now exposes 34 events: 27 of the 33 event names in the
[Claude Code hooks reference](https://code.claude.com/docs/en/hooks) checked on
November 15, 2026, plus three synth-specific events. This is trigger coverage
for synth's existing features, not full Claude Code hook protocol or product
parity. Payloads, allowed effects, handler types, and watching differ as
specified in [Hooks](hooks.md).

## Shared triggers

| Claude Code event | Synth integration |
| --- | --- |
| `SessionStart` | Deferred startup, clear, resume, successful compaction |
| `SessionEnd` | Main-session shutdown, clear, resume; bounded cleanup |
| `UserPromptSubmit` | Prompt and steering admission before persistence |
| `UserPromptExpansion` | ACP skill command expansion before submission |
| `PreToolUse` | Effective tool identity before policy, approval, checkpoints |
| `PermissionRequest` | A call needs approval |
| `PermissionDenied` | Automatic approval judge denies a call |
| `PostToolUse` | Successful worker and owner-thread tools |
| `PostToolUseFailure` | Executed worker tool returns an error |
| `PostToolBatch` | Entire assistant tool batch settled, including denials and user answers |
| `TaskCreated` | Normalized todo item added; whole-list mutation can be rejected |
| `TaskCompleted` | Todo item enters `done`; whole-list mutation can be rejected |
| `SubagentStart` | Task child starts |
| `SubagentStop` | Child completion before delivery to parent |
| `Stop` | Normal root-turn completion, with bounded continuation |
| `StopFailure` | Agent API/provider request terminates with an error |
| `Notification` | Notices, permissions, input waits, completion, idle reminder, ACP auth success |
| `InstructionsLoaded` | Actual project instruction load into the prompt cache |
| `ConfigChange` | Main config, hook files, discovered skill file changes; hook-definition adoption gate |
| `CwdChanged` | Explicit session cwd changes through `/cd`, the `cd` tool, or ACP |
| `DirectoryAdded` | `/add-dir` and ACP root registration, after updating file permissions |
| `FileChanged` | Configured literal project-root files added, changed, removed |
| `PreCompact` | Manual or automatic compaction begins |
| `PostCompact` | Compaction succeeds |
| `PreModelSwitch` | Explicit model selection, before changing the provider |
| `PostModelSwitch` | Actual model change, including automatic changes and restoration |
| `MessageDisplay` | Assistant display batches, with transient text replacement |

The 16 newly added names are `UserPromptExpansion`, `PermissionDenied`,
`PostToolUseFailure`, `PostToolBatch`, `TaskCreated`, `TaskCompleted`,
`StopFailure`, `Notification`, `InstructionsLoaded`, `ConfigChange`,
`FileChanged`, `PreModelSwitch`, `PostModelSwitch`, `MessageDisplay`,
`CwdChanged`, and `DirectoryAdded`.
Non-tool matcher fields now select the applicable source, reason, notification,
agent type, compaction trigger, instruction load reason, target model, or error.

Synth-specific `Interrupt`, `PreModelRequest`, and `PostModelRequest` remain
available. Model request events include attempts and retries for normal turns,
classification, and compaction; they complement the terminal `StopFailure`.

## Events requiring absent features

These six names are rejected during configuration parsing rather than
silently accepted without a trigger:

| Event | Prerequisite synth does not expose |
| --- | --- |
| `Setup` | Explicit initialization/maintenance execution mode |
| `TeammateIdle` | Agent teams with independently idle teammates |
| `WorktreeCreate` | Agent-owned isolated worktree creation |
| `WorktreeRemove` | Agent-owned isolated worktree removal |
| `Elicitation` | Interactive server-initiated MCP elicitation |
| `ElicitationResult` | Completion of interactive MCP elicitation |

Synth can detect a checkout already inside a worktree, but does not own that
worktree's lifecycle. The MCP client declines server-initiated input requests;
adding event names would not create a usable elicitation UI.

## Compatibility and verification

Flat legacy `PostToolUse` keeps receiving successes and errors. Grouped
`PostToolUse` now runs only on success: move error handling to
`PostToolUseFailure`. New declarations require explicit trust as usual.

File watching uses metadata polling, coalesces rapid changes, and supports
literal filenames under the project root. Dynamic `watchPaths` output and
Claude environment-file effects are not implemented. Main settings and skills
keep their existing reload lifecycle. Display replacements affect presentation
only; original text remains in SQLite and model history and reappears on resume.
Task events use synth's normalized todo list rather than a separate task store.

Cwd changes are explicit session operations. A `cd` inside `bash` remains local
to that subprocess; models use the dedicated `cd` tool for a persistent change.
This differs from Claude Code's shell-directory tracking. The `cd` tool must be
the only call in its batch, preserving the path meaning of sibling approvals.
Cwd and additional roots stay in the running session and are not stored as
SQLite workspace configuration. Hook discovery and project instructions remain
anchored to the original project; adding a root does not trust its hook files.

Checked-in input/result fixtures cover all 34 registered synth events. Runtime
regressions cover worker success/failure separation, full parallel and owner
batches, atomic task gates, automatic permission denial, terminal provider
errors, explicit model-switch denial, instruction cache loads, skill-expansion
admission, external idle file/config changes, notification deduplication,
config adoption policy, session transitions, and display/canonical separation.


## Synth routing for local and decision models

Synth additionally supports [targeted routing](hooks.md#targeted-routing) with
exact `when` selectors for agent scope, request purpose, role, model, and
provider. The same hooks apply to main agents and children. Automatic approval
judge requests, ordinary agent requests, and compaction requests carry distinct
purposes, preserved through retries. Parent agent/delegation ids link child
activity to its owner. These are synth extensions, independent of model support;
they neither select an inference backend nor grant a hook additional authority.

Four additional synth request customization stages (`ModelResolve`,
`ModelSettings`, `ModelContext`, and `ModelRetry`) provide typed, synchronous
controls alongside observational request-attempt events. See [hooks](hooks.md#model-request-customization).
