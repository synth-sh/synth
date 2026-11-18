# Changelog

## Unreleased

- Expand hooks across agent lifecycle, permissions, model requests, and inference HTTP.
- Add targeted policies for main agents, subagents, and independent decision models.
- Require hook declarations to be reviewed and trusted, or disabled, before prompts run.
- Keep file permissions unchanged when the session working directory changes.
- Make streamed-record adapters opt-in with `stream: true`.
- Keep permission grants with the user or normal decision review; hook `allow` does not grant access.

## Upgrading hooks

- Review and trust existing hooks, or disable them, before prompts run. Interactive sessions retain the queued prompt and resume it once review is complete.
- Missing executables, malformed synchronous outputs, and malformed hook configuration block the affected work. Hook commands run without loading a login profile.
- Add `stream: true` to handlers that need individual streamed records. Response headers remain available without it.
- The path-protection example and offline CLI tests require Python 3.
- Trust grants and enable operations require at least 32 ID characters. Relative user commands stay scoped to each checkout; absolute commands with absolute file arguments can share trust.
- Editing Synth control files or literal script paths referenced by trusted hooks requires human approval, including under auto mode and additional roots. Hook scripts and their dependencies still run with the user's process permissions.
