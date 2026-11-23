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

## Copying

Drag with the mouse to select, and let go to copy: the text goes to the
clipboard over OSC 52, which works over ssh too. A selection stays in the part
of the screen it started in, so dragging from the transcript never picks up the
sidebar or the composer, and the bars, rules and hints drawn around the text are
left out of what is copied.

In the transcript a selection can reach past the screen: scroll with the wheel
while dragging, or hold the pointer at the top or bottom edge and the view
scrolls by itself. What is copied is what the transcript draws, so a collapsed
card copies as its one line; expand it first to copy what it holds.

Most terminals select on their own while a modifier is held, usually `shift`,
and that selection is the terminal's, not synth's.

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

Use `/approvals auto` to send actions that would prompt for approval to a
model reviewer. It sees your requests, answers, and relevant actions. Broad
shell allowances such as `npm run *` still go to review. Preset read-only
shell commands skip review by default, including commands that read outside the
project. Set `auto_approve_safe_commands` to `false` to review those commands.

The session model reviews calls by default. Use [models by request purpose](configuration.md#models-by-request-purpose)
to configure a separate reviewer, deadline, or fallback. With the default
fallback, three refusals in a row or twenty in a session return decisions to
you. With `reviewer_fallback: "deny"`, repeated refusals stop the turn.
Use `/approvals ask` to return to interactive approval.

### Rewind

`/rewind` undoes what turns did to files. Before `write` or `edit` first changes
a file in a turn, synth keeps what the file held; `/rewind` lists the prompts
that changed files, shows what going back to before one would put back, flags
anything changed since by other means, and restores it. Files changed through
the shell are not tracked, and the transcript stays as it was.

## Hooks and workspace

`/hooks review` shows configured hooks. Use `/hooks trust <id>` to approve a
reviewed declaration, or `/hooks disable <id>` to continue without it. See
[Hooks](hooks.md) for configuration and controls.

`/cd <path>` changes the session working directory; `/cd` shows it. File
access follows the project root and any roots explicitly permitted with
`/add-dir <path>`. Both commands require an idle session and accept paths
containing spaces.
