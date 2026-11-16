# Features enabled by Synth hooks

Synth hooks let trusted policies shape agent work independently of the model.
The same system covers the main agent, subagents, approval review, and compaction.
Handlers can target a scope, role, model, provider, or request purpose.

| Feature | What it enables |
| --- | --- |
| Request-scoped routing | Inspect conversation and tool history, then choose a permitted local or remote route for the next request without changing the session model. |
| Context and tool selection | Prepare model-specific instructions, excerpts, images, attachments, reasoning, and tool results on a request copy. Offer a smaller tool set and reject calls to excluded tools. |
| Generation controls | Tune supported sampling options, reasoning effort, stop sequences, and output limits for the selected protocol. |
| HTTP adapters | Add headers and normalize request JSON, response JSON, or streamed SSE/NDJSON records before parsing. Supports Chat, Responses, Messages, and Ollama. |
| Retry policies | Recover from a custom HTTP failure, veto retries, or adjust delay within the configured attempt ceiling. |
| Permission evaluation | Apply deterministic or externally implemented decision policies to otherwise allowed calls as well as calls needing approval. An explicit denial stays final; an explicit ask reaches the user. |
| Independent review | Use a separate decision model with a deadline and an ask-or-deny fallback. Preserve verified human intent and approvals tied to execution evidence. |
| Lifecycle automation | Observe or gate prompts, tools, batches, tasks, completion, workspace changes, and other supported lifecycle events. Background context stays with its owning agent. |

Request preparation preserves canonical history and authorization provenance.
HTTP adapters cannot select another destination or routed model, and cannot alter
approval-review evidence. They are trusted protocol code: their rewrites must
preserve the meaning of tool-call identifiers and completion markers. Shell and
hook execution still use process permissions; hooks do not provide an OS sandbox.
WebSocket interception, catalog transforms, and process monitors are outside this
feature set.

## Verification

`zig build test` runs unit and regression coverage. `zig build test-hook-requests`
requires Python 3 and drives the built CLI against isolated local HTTP servers.
The latter checks actual routing and wire payloads, canonical-history retention,
excluded-tool rejection, four protocol adapters, bounded retries, permission
outcomes, and blocked endpoint/model/reviewer overrides. It does not measure live
provider compatibility or reviewer accuracy.

See [Hooks](hooks.md) for configuration, payloads, composition rules, and limits.
See [Validation and review](hooks-validation.md) for results and review fixes.
