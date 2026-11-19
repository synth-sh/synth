# CLI

```
synth [project]                start the TUI (default)
synth run [--allow] <message>  one headless turn, no TUI
synth session list|show|rm     sessions for this project
synth session search <text>    find text in this project's transcripts
synth hooks list|review       inspect hooks and trust status
synth hooks trust|revoke <id>  change trust for a reviewed definition
synth hooks enable|disable <id> control whether a hook runs
synth mcp list|auth|logout     MCP servers, and signing in to one
synth mcp enable|disable|debug turn one on or off, or see what discovery finds
synth db status|prune|vacuum   what the database holds, and shrinking it
synth skills                   skills on offer, and where they came from
synth models                   models the provider offers
synth prompt                   print the system prompt
synth acp                      speak the Agent Client Protocol on stdio
synth remote list <host>       sessions on a host over ssh (. is this machine)
synth remote connect <host>    drive one in the TUI: name its id, or pick
synth remote new <host> [dir]  start one there, in your home by default

  -c, --continue               resume the most recent session here
  -s, --session <id>           resume a session by handle (ses_7k3f9a2b)
  -m, --model <name>           override the model, this run only
      --allow                  run only: allow ordinary approval prompts
```

`synth run` drives one turn and prints each step. By default it declines
operations that prompt for approval. `--allow` authorizes ordinary approval
prompts. Calls that specifically require a human are refused in headless runs.

## ACP

`synth acp` is synth as an [ACP](https://agentclientprotocol.com) agent, for an
editor to spawn: each session it opens runs in a process of its own, and
approvals are asked as permission requests. Loading a session that is running
elsewhere attaches to it there. An editor that offers its own view of files
gets reads and edits through it, unsaved changes included, and one that keeps
terminals runs commands in them, shown in the call as they run. MCP servers
the editor brings connect beside those in `config.json`, which wins a clash of
names. ACP offers skills, `/compact`, `/hooks`, `/cd`, and `/add-dir` as
slash commands.

Quitting stops the session, a turn in progress included, unless another
terminal is attached to it. `/detach` leaves it running instead, and so does
losing the terminal without quitting, a closed window or a crash:
`synth --session <id>`, `--continue` or `/sessions` attach to it again from
any terminal, and quitting from there stops it. Each session listens on a
socket in `$SYNTH_SOCKET_DIR`, else `/tmp/synth-<uid>`. An editor's sessions
stop when the editor goes.

### Synth ACP extensions

Clients opt in with `"_meta": {"synth": {"protocol": 2}}` in `initialize`.

| Method | Params | Effect |
| --- | --- | --- |
| `_synth/change_directory` | `{"sessionId":"…","path":"…"}` | Change the working directory of an idle session. |
| `_synth/add_directory` | `{"sessionId":"…","path":"…"}` | Add a permitted file root to an idle session. A new root emits `DirectoryAdded` with `source: "register_repo_root"` by default. |
| `_synth/hooks` | `{"sessionId":"…","action":"review"}` | Return a hook report. Use `id` for `trust`, `revoke`, `enable`, and `disable`, which require an idle session. The default action is `list`. |

`_synth/status` includes `cwd` and `additional_roots`. The `root` and
`project` fields identify the original project.

## Remote

`synth remote` reaches the sessions on another machine the same way, over
ssh: your ssh config, keys and jump hosts apply, and synth must be on the far
end's `PATH`. There `synth remote bridge` attaches to a running session or
starts `synth acp` under your login shell, so tools see the environment a
login there would. A remote session keeps running when the connection
drops, as it does after `/detach`, and `synth remote connect <host>` with no
id offers the sessions there to pick from.

## Hook review

Run `synth hooks review` from the project to inspect hook definitions and
trust status without executing hooks or connecting to a model provider.
See [Hooks](hooks.md#configuration-and-trust) for trust and enable controls.
