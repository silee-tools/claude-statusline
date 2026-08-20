# claude-statusline

This repository publishes two Claude Code plugins through one marketplace,
`silee-tools`. The sections up to and including [Development](#development)
document `claude-statusline`; [stuck-resume](#stuck-resume) follows
them in its own section.

## claude-statusline

A width-aware statusline HUD for [Claude Code](https://code.claude.com). It
shows location, accounts, session state, context usage, rate limits, reasoning
effort, and cost without forcing the same layout onto every terminal.

At 80 columns or fewer, the compact layout uses up to three rows:

```text
17:14 ~/↪1/webapp/↪1/src feature/PROJ-123-post-editor
dev@example.com gh@personal aws:✓ v3.1.0 ⧉ 3f9c1a
ctx 68% Opus 4.8 ● 5h 47% ↺2h30m 7d 83%▲ ↺3d16h
```

At 81 columns or more, the full layout uses up to seven rows:

```text
17:14 ~/↪1/webapp/↪1/src feature/PROJ-123-post-editor
dev@example.com gh@personal aws:✓
 ctx █████████████░░░░░░░ 68% Opus 4.8 ●
  5h █████████░░░░░░░░░░░ 47% ↺2h30m
  7d ████████████████▓░░░ 83% ↺3d16h
cost 24h Opus $12 / 7d $42 / 31d $105
v3.1.0 ⧉ 11111111-2222-3333-4444-555555555555
```

Rows with no data are omitted in either layout.

## Width selection

`CLAUDE_STATUSLINE_WIDTH` overrides automatic detection when it contains only
digits. Otherwise the statusline follows the parent process chain to a tty, up to
four levels, and asks that device for its current window size. It caches only the
tty path; the size is read again on every render so a terminal resize takes
effect on the next update. `COLUMNS` is intentionally ignored because an exported
value can stay stale after a resize.

The full layout is selected when width detection fails. This fallback keeps
all information visible when the available width is uncertain.

## Layouts

The compact layout groups related values into three rows:

- **Row 1 (location)** contains time, the current path, and the git branch.
  Its display width is capped at the detected terminal width. With a branch,
  the path and branch share `width - 8` columns; without one, the path can use
  `width - 6`. Overflow is marked with `…`, ANSI color codes count as zero
  width, and wide characters such as Hangul and CJK are never split.
- **Row 2 (identity and constants)** contains the Claude account,
  `gh@<account>`, `aws:<session>`, the Claude Code version, and the first six
  characters of the session id.
- **Row 3 (gauges)** contains context usage, model, reasoning effort, and the
  5-hour and 7-day limits. Rate data that is absent is omitted independently.

The full layout keeps the location and identity rows, gives `ctx`, `5h`, and
`7d` separate 20-cell gauge rows, restores the cost row, and puts the version
and full session id in a footer. Its first row is not truncated. Widths from
81 through 85 can therefore wrap when both the shortened path and branch are
long.

The path collapses `$HOME` to `~`, preserves repository and current-directory
names, and marks skipped segments as `↪N`. The branch and session glyphs need a
Nerd Font; without one they may render as placeholder boxes.

## Gauges and cost

Both layouts use the same thresholds. Context usage turns yellow at 40% and
red at 70%; rate usage turns yellow at 80% and red at 90%.

The `5h` and `7d` gauges also compare usage with the elapsed-time budget. The
compact layout adds `▲` after the percentage when usage is ahead of pace. The
full layout colors the filled bar cells beyond the pace budget with `▓`.
Small overshoots are yellow and overshoots of about 15 percentage points or
more are red. The comparison uses 20 five-point cells, so the boundary is
quantized rather than exact.

Cost is displayed only in the full layout. The background cost cache is
refreshed for both layouts, so switching widths does not require new
collection.

## Reasoning effort

Effort is shown with the same circle glyphs Claude Code uses in its session
header, plus a warm-gauge color: `low ○` (green) · `medium ◐` (lime) ·
`high ●` (yellow) · `xhigh ◉` (orange) · `max ◈` (red) · `ultracode ✦`
(magenta). It is omitted when no effort information is available.

## Install

Requires [Claude Code](https://code.claude.com), a POSIX `sh`, `awk`, and
[Go](https://go.dev) 1.26 or newer. Go builds the render binary once on this
machine — see [First run](#first-run) below. `git` powers the branch display.
`ps` provides automatic terminal-width detection. `curl` is optional: it
refreshes the model pricing
table once a day from the public
[LiteLLM price table](https://github.com/BerriAI/litellm); without it (or if
the fetch fails), a built-in price table is used. The full layout displays a
per-model cost tally (`24h` / `7d` / month) computed directly from local Claude
Code session logs
(`~/.claude/projects/**/*.jsonl`) and cached under
`${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline/`.

```shell
claude plugin marketplace add silee-tools/claude-statusline
claude plugin install claude-statusline@silee-tools
claude   # restart
```

On restart, the plugin's `SessionStart` hook wires `statusLine` in
`~/.claude/settings.json` automatically and refreshes the cost cache in the
background — no manual `settings.json` edit is needed.

### First run

The render binary is not shipped in the repository; it is built on this machine
so that no prebuilt object has to be trusted or kept in the git history. The
same `SessionStart` hook builds it in the background, into
`${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline/bin/`, once per plugin
version and platform. A cold build takes a few seconds.

Until that build finishes, the statusline shows one line with the current
directory and `statusline: binary not built yet`, and the next render after it
finishes shows the normal layout. The same line appears when Go is missing: the
hook writes a note to stderr and leaves session start untouched, so installing
Go and starting a new session is all that is needed.

The build uses the standard library only and runs with `GOPROXY=off`, so it
needs no network.

### Dependencies

| Tool | Required? | Used for |
|---|---|---|
| `go` 1.26+ | required | building the render binary once per plugin version |
| `sh` (POSIX) | required | the statusline shim, the session hook, and the background jobs |
| `awk` | required | parsing the hook JSON and aggregating the background cost cache |
| `git` | required | the branch indicator |
| `ps` | optional | automatic terminal-width detection (falls back to the full layout) |
| `curl` | optional | daily model-pricing refresh (falls back to a built-in table) |
| `saml2aws` | optional | the `aws:` session indicator |

## Configuration

### GitHub account indicator

The `gh@<account>` segment maps the current GitHub login to a label and color.
The mapping is not hardcoded — it is read from
`${XDG_CONFIG_HOME:-$HOME/.config}/claude-statusline/gh-accounts`, one entry per
line:

```
# <github-login>=<label>,<256-color-code>
octocat=personal,214
some-work-login=work,27
```

The current login and its status are read from
`${XDG_DATA_HOME:-$HOME/.local/share}/gh-prompt-user` (written by your shell
prompt). The file holds one tab-separated record:

```
v2	<login-or-->	<state>	<deadline-epoch-or-0>
```

Each state renders differently: `ok` shows `gh@<label>`, `rate_limited`
appends a yellow `⏳<minutes>m` until the deadline passes, `auth_failed` shows
a red `gh@<label>!`, `unknown` shows a grey `gh@<label>?`, and `no_active`
shows `gh@---`. A single line without tabs is read as a bare login, so a
prompt that records only the login still works. An unmapped login shows
`gh@<login>`; an empty or malformed file shows `gh@?`; color codes must be
numeric.

### Claude account indicator

The logged-in Claude account email is read (read-only) from the
`oauthAccount.emailAddress` field of `${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json`,
Claude Code's own account state. Only that one field is scanned, and the result
is cached until the file changes, so the large config file is not parsed in full
on every render. The segment is
omitted when the file or the field is unavailable. Nothing is written to that
file.

### Customizing

Colors, glyphs and value formatting live in
`claude-statusline/internal/theme/`, and the two layouts are assembled in
`claude-statusline/internal/render/`:

- **Gauge thresholds** — the numbers passed to `theme.GaugeColor`: 40/70 for
  context and 80/90 for the rate windows.
- **Effort colors and glyphs** — `theme.EffortGlyph`.
- **Branch shortening length** — `maxWords` in `internal/shorten` (default 4).
- **Layout switch point** — `compactAtOrBelow` in `cmd/statusline` (default 80).

A change here reaches the statusline only after the binary is rebuilt, which
happens on the next session start once the plugin version changes.

## Development

```shell
sh -c 'rc=0; for t in */tests/*.test.sh; do sh "$t" || rc=1; done; (cd claude-statusline && go test ./...) || rc=1; exit "$rc"'
```

The render path is Go with no external modules; the remaining scripts are POSIX
`sh`. `statusline.test.sh` builds the binary, points the shim at it, and asserts
both layouts, gauges, colors, and indicators against fixture JSON.
`shim.test.sh` asserts what the shim shows with and without a binary and that the
build is idempotent. The Go tests cover display width and cutting,
terminal-width decisions, path and branch shortening, the account decision
table, and the gauge thresholds.

## stuck-resume

A `StopFailure` hook that resumes a turn something else cut short. Two causes
trigger it: the account hitting its 5-hour or 7-day usage limit, and the login
expiring mid-turn. In both cases the hook waits, then wakes the model with a
short prompt naming the cause, so the session picks the work back up without
anyone typing "continue".

The hook never repairs the login itself. Running `/login` is a person's job, or
another session's; this hook only waits and then wakes the interrupted turn. If
the login is still expired when the model wakes, the new turn is rejected and
the hook waits again.

### Install

```shell
claude plugin marketplace add silee-tools/claude-statusline
claude plugin install stuck-resume@silee-tools
claude   # restart
```

No `settings.json` edit is needed. `hooks/hooks.json` is auto-discovered and
matches only the `rate_limit` and `authentication_failed` errors, so no other
stop reason triggers it.

Coming from `rate-limit-resume`: the plugin name is its install identifier, so
this rename is not an upgrade path. Remove the old plugin and install the new
one.

```shell
claude plugin uninstall rate-limit-resume@silee-tools
claude plugin marketplace update silee-tools
claude plugin install stuck-resume@silee-tools
claude   # restart
```

Uninstalling leaves the old counter directory
`${XDG_STATE_HOME:-$HOME/.local/state}/rate-limit-resume/` behind. Nothing reads
it any more, so delete it by hand whenever convenient.

### How it works

Claude Code fires `StopFailure` with an `error` value naming why the turn ended:
`rate_limit` against a usage limit, and `authentication_failed` when the login
expired, which is the stop that shows "Login expired · Please run /login". The
hook entry sets `asyncRewake`, so the command runs in the background while the
session sits idle. `resume.sh` sleeps for `CLAUDE_RESUME_WAIT_SECONDS` and then
exits with code 2 — the code that tells Claude Code to wake the model — and
whatever it wrote to **stderr** becomes the prompt for the new turn. Text on
stdout is not injected. That prompt names the cause, so the model does not
resume on the wrong assumption about what stopped it.

The hook reads neither the reset time nor the login state, since neither reaches
it as a machine value. It polls instead: if the cause still holds, the new turn
is rejected, `StopFailure` fires again, and the next wait starts. A rejected
attempt is refused before any tokens are billed, so polling costs nothing but
elapsed time.

An attempt counter under
`${XDG_STATE_HOME:-$HOME/.local/state}/stuck-resume/` bounds that loop, keyed by
session and cause together. Spending every retry on a usage limit therefore
leaves that same session free to retry an expired login. Once one
session-and-cause pair passes `CLAUDE_RESUME_MAX_ATTEMPTS`, the hook exits 0 and
the session stays stopped. Counter files older than seven days are cleaned up on
each run.

### Settings

| Variable | Default | Meaning |
|---|---|---|
| `CLAUDE_RESUME_WAIT_SECONDS` | `120` | seconds to wait before waking the model |
| `CLAUDE_RESUME_MAX_ATTEMPTS` | `90` | attempts per session and cause before giving up |
| `CLAUDE_RESUME_STATE_DIR` | `${XDG_STATE_HOME:-$HOME/.local/state}/stuck-resume` | where attempt counters are kept |

The variable names still read `CLAUDE_RESUME_` rather than the plugin name, so a
configuration that already sets them keeps working across the rename.

Keep the wait below the `timeout` in `hooks/hooks.json` (600 seconds); a longer
wait is cut off and the session is never resumed. With the defaults, one
session-and-cause pair retries for roughly three hours before it gives up.

### Limits

Resuming needs a live interactive session. Under `claude -p` the process exits
before the background hook finishes, so nothing is resumed.

Neither trigger has been exercised against a real usage limit or a real expired
login. The resume mechanism was verified with a stand-in `Stop` hook, the two
matcher values come from Claude Code's own list of `StopFailure` error values,
and the rest is covered by injecting hook input into `resume.sh` directly.

## License

[MIT](LICENSE)
