# Hooks

Hooks run commands or MCP tools when Synth events occur.

## Block edits to protected files

1. Copy the [path-protection script](../examples/hooks/protect-paths.py) to
   `.synth/protect-paths.py` in your project. It requires Python 3.
2. Add this to `.synth/hooks.json`:

   ```json
   {
     "PreToolUse": [{
       "matcher": "^(write|edit)$",
       "hooks": [{
         "command": "python3 \"$SYNTH_PROJECT_DIR/.synth/protect-paths.py\""
       }]
     }]
   }
   ```

3. Run `/hooks review`, inspect the definition and script, then run
   `/hooks trust <id>` with the reviewed ID.
4. Ask Synth to create a placeholder `.env` file. The hook blocks the write.

## Configuration and trust

Synth combines `config.json`'s `hooks`, `~/.synth/hooks.json`, and the
original project's `.synth/hooks.json` in that order. Use an event map at
the top level of each standalone file.

Commands run as you from `$SYNTH_PROJECT_DIR`, without Bash profiles.
Use the payload's `cwd` for relative tool paths. Trust covers the
declaration. Review the script and its dependencies separately.
File-tool edits to Synth control files, `.git/`, `.synth/`, and literal
script paths referenced by trusted commands require human approval.

After a definition changes, trust or disable it before submitting a prompt.
The [CLI](cli.md#hook-review) and `/hooks` take the same subcommands.
Use at least 32 ID characters for `trust` or `enable`, eight for `revoke` or
`disable`. Prefixes must be unique. User hooks with absolute commands and
file arguments can share trust across checkouts.

## Handlers and matching

Each event takes an array of groups. Put the handlers in each group's
`hooks` array, with optional `matcher` and `when` fields alongside it.
Matchers use regular expressions and recognize tool names and aliases such
as `Bash` and `Edit`. For `FileChanged`, use project-relative paths such as
`subdir/.env`, separated by `|`. An omitted matcher runs for every occurrence
of the event.

Use `timeout_ms` (milliseconds) or `timeout` (seconds) to override
[`hook_timeout_ms`](configuration.md). Command handlers accept `async: true`
for background context or diagnostics. Permission and request preparation
require synchronous handlers. Use `transcript: true` to request a private
snapshot at `transcript_path`.

For synchronous MCP handlers use `type: "mcp_tool"`, `server`, `tool`, and
`arguments`. Interpolate with `${input.field.path}`. Whole-value references
preserve the JSON type. Session shutdown supports command handlers only.

### Targeted routing

Add `when` beside `matcher` to filter by `agent_scope` (`main`, `subagent`),
`request_purpose` (`agent`, `approval_judge`, `compaction`), `agent_type`,
`model`, or `provider`. All filters must match.

## Events

| Events | Control |
| --- | --- |
| `SessionStart`, `UserPromptSubmit` | Supply context or block admission |
| `UserPromptExpansion`, `ConfigChange`, `PreModelSwitch` | Reject the proposed operation |
| `PreToolUse` | Reject, request approval, replace arguments, or supply context |
| `PermissionEvaluate` | Deny or require human approval |
| `PermissionRequest` | Deny a call awaiting approval |
| `PostToolUse`, `PostToolUseFailure` | Add context or diagnostics. Successful MCP results also accept feedback. |
| `PostToolBatch` | Supply context or stop before the next model request |
| `TaskCreated`, `TaskCompleted` | Reject a todo-list change |
| `PreCompact`, `PostCompact` | Stop compaction or its automatic continuation |
| `Stop`, `SubagentStop` | Request further work within the existing turn budgets |
| `SubagentStart` | Observe child creation or supply context |
| `PermissionDenied` | Observe a denial or use `retry` to tell the agent it may try again |
| `SessionEnd`, `Interrupt`, `StopFailure`, `Notification`, `InstructionsLoaded`, `FileChanged`, `PostModelSwitch`, `CwdChanged`, `DirectoryAdded` | Observe |
| `MessageDisplay` | Replace displayed text via `displayContent` |
| `PreModelRequest`, `PostModelRequest` | Observe each physical transport attempt |
| `ModelResolve`, `ModelSettings`, `ModelContext`, `ModelRetry` | Prepare a request or decide a retry |
| `HttpRequest`, `HttpResponse` | Adapt inference HTTP payloads |

## Input and output

Read one JSON object from stdin. It includes `hook_event_name` and `cwd`.
Tool events include `tool_name`, `tool_input`, and `tool_call_id`. Decode
JSON strings such as `action` and `http` before reading their fields.

Exit 2 blocks supported operations with a reason from stderr. With exit 0,
handlers can write structured JSON to stdout:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "This file is protected"
  }
}
```

Use `updatedInput` to replace tool arguments. File tools accept aliases
such as `file_path`, `old_string`, and `new_string`. Conflicting edits to an
argument cause rejection. A hook's `allow` leaves approval to normal policy.
A mandatory human approval is refused in headless mode, even with `--allow`.

## Model requests

Return these fields in `hookSpecificOutput`. See [model routes](configuration.md#models-by-request-purpose).

| Event | Output |
| --- | --- |
| `ModelResolve` | `route` selects a route ID allowed for the current purpose. |
| `ModelSettings` | `settings` sets supported generation and retry controls. Unsupported settings block the request. |
| `ModelContext` | `requestContext` can set `system`, `instruction`, allowed `tools`, and `messages` edits by `seq`. Keep tool calls paired with their results. Approval-review evidence is protected. |
| `ModelRetry` | `retryAllowed` can permit or veto a retry within transport limits. `retryDelayMs` sets the delay. |

## HTTP adapters

For Chat, Responses, Messages, and Ollama inference, decode the input's
`http` string and return `hookSpecificOutput.http`. Known credential headers
are redacted. Destinations, routed models, and reviewer evidence are protected.

| Phase | Output fields |
| --- | --- |
| `request` | `headers`, replacement JSON object `body` |
| `headers` | `headers`, `status` |
| `body` | replacement JSON `body` |
| `event` | `body` or `drop: true` for an SSE or NDJSON record |

Set a header to `null` to remove it. Set `stream: true` on each
`HttpResponse` handler that needs records.

## Troubleshooting

- **Prompt blocked for review.** Trust or disable pending hooks, then
  resubmit the prompt from the composer.
- **Hook fails or times out.** Use `/hooks list` to inspect recent runs.
  Check `PATH`, script paths, and timeouts. Missing commands and malformed
  synchronous policy output can block the operation.
- **JSON has no effect.** Exit 0 and emit only JSON on stdout. Check that
  the effect is supported by the event.
