# Using synth

## Keys

| key | what it does |
| --- | --- |
| `enter` | send, steer the turn already running, or run the highlighted `/` command |
| `tab` | cycle mode: build, plan, review; in the `/` menu, complete the command |
| `esc` | cancel the turn, reject a pending call, or close what is open |
| `ctrl+o` / `ctrl+p` / `ctrl+s` | model / provider / session |
| `ctrl+r` | rename this session |
| `ctrl+t` | collapse or expand the plan |
| `ctrl+e` | compose the draft in `$EDITOR` |
| `ctrl+v` | paste an image |
| `ctrl+c` | clear the draft, interrupt a turn, then quit |
| `ctrl+z` | suspend to the shell |

In the `/` menu, Enter completes a skill, a command missing a required argument,
or a partial `/clear`, `/compact`, `/prune`, or `/logout`. Tab always completes.

`/help` lists the slash commands. `@path` pulls a file into the prompt - an
image comes along as a picture, and a name with spaces is written
`@"Pasted image.png"`.

`ctrl+e` hands the draft to `$VISUAL`, or `$EDITOR`, and takes back what was
saved. The value is run through a shell, so `EDITOR="code -w"` works as long as
it waits.

## Searching

`synth session search <text>`, or `/search <text>` inside the TUI, looks through
every transcript in the project. What was said comes first and tool output
after, since a search is usually after the conversation rather than a file a
tool printed.

The match is plain text, not a query language, so `100%` searches for `100%`.

## Modes

`tab` cycles three. **Build** can read, write and run. **Plan** is read
only and answers with a plan rather than changes. **Review** can read and run
commands - tests, `git diff`, a build - but cannot edit.

Anything that changes the project or runs a command asks first, and a preset of
read-only shell commands skips the prompt.

"Allow always" remembers the answer for the project, as narrowly as it can: a
shell command is allowed by its subcommand (`git commit *` does not cover
`git push`), and a program without one by the exact command. `↑`/`↓` on the
prompt widens or narrows that before it is saved. `/permissions` lists what is
allowed; `enter` edits a pattern, `del` removes it, and typing a command that is
not there offers to add it. A change holds in every session on the project at
once.

### Auto approvals

`/approvals auto` (or `"approvals": "auto"` in `config.json`) hands those
decisions to a configured reviewer instead (the session model by default). Reads, the safe commands, narrow
allowances and edits inside the project run as before; everything else is
judged first, by a model shown only what you asked for and the calls the agent
has made - not what the agent said, and not what any tool returned. Text
planted in a file reaches it only inside a call's arguments (a heredoc, a file
being written), fenced off as data it is told not to follow. The safe commands
skip it as they skip the prompt, wherever they point: `cat ~/.ssh/id_rsa` runs
unjudged unless `auto_approve_safe_commands` is off. It blocks what looks destructive,
reaches outside the project, sends data out, touches credentials, or goes past
the task, and a block reaches the agent as a refused call with the reason.
Allowances that would run anything (`python3 *`, `npm run *`) are set aside
while it judges. With the default fallback, three blocks in a row, or twenty in a session, hand decisions
back to you. `/approvals all` runs everything without asking; `/approvals ask`
goes back to the prompt.

### Rewind

`/rewind` undoes what turns did to files. Before `write` or `edit` first changes
a file in a turn, synth keeps what the file held; `/rewind` lists the prompts
that changed files, shows what going back to before one would put back, flags
anything changed since by other means, and restores it. Files changed through
the shell are not tracked, and the transcript stays as it was.

## Hook review

Use `/hooks` to list lifecycle hooks and their trust/enable state, source,
matcher, timeout, mode, and recent results. `/hooks review` shows their exact
definitions. After reviewing one, `/hooks trust <id>` permits it to execute;
`/hooks revoke <id>` removes trust, and `/hooks disable <id>` or
`/hooks enable <id>` changes enablement separately. Trust changes require an
idle session and an explicit user operation. These operations also exist as
`synth hooks ...` for headless use and through ACP's `_synth/hooks` request.

Existing hooks need review after upgrade. A pending review is shown before a
prompt can reach the model. Definition changes invalidate its old trust id.
See [Hooks](hooks.md) for lifecycle behavior and configuration examples.


## Session directories

`/cd <path>` changes where subsequent relative tool paths and shell commands
resolve. `/cd` shows the current directory. The model has a `cd` tool for the
same persistent change; it must run in its own tool batch. A `cd` inside a
`bash` command affects only that shell subprocess.

`/add-dir <path>` adds another directory to the session's permitted file roots.
Read-only file tools can access that root without an outside-project prompt;
mutating tools still follow the usual approval policy. Absolute and relative
paths are accepted, including spaces; paths are resolved physically and must
name an existing directory. Duplicate roots and paths inside an existing root
are ignored. Both commands require an idle session.

A user-requested `/cd` permits the new cwd as a file root while it is active.
An agent-requested `cd` outside the permitted roots needs normal approval.
The original project stays accessible, and explicitly added roots remain
accessible across cwd changes. Directory state belongs to the running session;
a fresh process or reopened saved session starts from its normal project root.
These commands do not change another session or reload hooks, skills, or
instructions from the destination. Use absolute paths in hook declarations
when scripts must remain anchored to the original checkout.

Successful transitions emit `CwdChanged` or `DirectoryAdded` after the new state
is effective. Hooks cannot veto those transitions; ordinary pre-tool policy
can still deny a model's `cd` call.


## Routing security hooks

Hooks apply to the main agent and its task children. Use a
[`when` filter](hooks.md#targeted-routing) to select `agent_scope: "subagent"`,
a specific role/model/provider, or `request_purpose: "approval_judge"` for the
automatic judge's model requests. Ordinary requests use `agent`; summarization
requests use `compaction`. Scope and purpose appear in recent hook records.
Mandatory policy hooks can remain unfiltered so they cover every model and
agent. Local models do not need special hook support: synth dispatches policy
hooks before tool execution, and existing approvals still apply.

Configure a separate local decision model, review timeout, and `ask` or `deny`
fallback under [model_requests](configuration.md#purpose-based-models-and-approval-review).
With `deny` fallback, repeated denials stop the turn. Review uses verified human
intent and immutable execution evidence; hook text and summaries cannot supply
authorization.
