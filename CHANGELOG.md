# Changelog

## Unreleased

- Add [hooks](docs/hooks.md) for agent lifecycle events, permissions, model
  requests, and inference HTTP, with filters for subagents and request purposes.
- Configure separate [model routes](docs/configuration.md#models-by-request-purpose)
  for agent turns, approval review, and compaction.
- Use [`/cd` and `/add-dir`](docs/usage.md#hooks-and-workspace) to change the
  session's working directory and add permitted file roots independently.
