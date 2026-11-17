# Changelog

## Unreleased

- Expand hooks across agent lifecycle, permissions, model requests, and inference HTTP.
- Add targeted policies for main agents, subagents, and independent decision models.
- Require hook declarations to be reviewed and trusted, or disabled, before prompts run.
- Keep file permissions unchanged when the session working directory changes.
- Make streamed-record adapters opt-in with `stream: true`.
- Keep permission grants with the user or normal decision review; hook `allow` does not grant access.
