# claude-statusline

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
digits. Otherwise the statusline follows the parent process chain to a tty and
reads that device's current width. It caches only the tty path; the width is
read again on every render so a terminal resize takes effect on the next
update. `COLUMNS` is intentionally ignored because an exported value can stay
stale after a resize.

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

Requires [Claude Code](https://code.claude.com), a POSIX `sh`, and `awk`. `git`
powers the branch display. `ps` and `stty` provide automatic terminal-width
detection. `curl` is optional: it refreshes the model pricing
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

### Dependencies

| Tool | Required? | Used for |
|---|---|---|
| `sh` (POSIX) | required | running the scripts |
| `awk` | required | parsing the statusline JSON and aggregating the background cost cache |
| `git` | required | the branch indicator |
| `ps`, `stty` | optional | automatic terminal-width detection (falls back to the full layout) |
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
Claude Code's own account state. Only that one field is scanned with `awk`, so
the large config file is not fully parsed on every render. The segment is
omitted when the file or the field is unavailable. Nothing is written to that
file.

### Customizing

Shared data formatting lives in `claude-statusline/scripts/statusline.sh`, and
the two layouts are assembled in `render-compact.sh` and `render-full.sh`:

- **Gauge thresholds** — `set_context_gauge` (40/70) and `set_rate_gauge`
  (80/90).
- **Effort colors/glyphs** — `format_effort`.
- **Branch shortening length** — `max_words` in `shorten.sh`'s `shorten_branch`
  (default 4).

## Development

```shell
sh claude-statusline/tests/statusline.test.sh
sh claude-statusline/tests/fit.test.sh
sh claude-statusline/tests/width.test.sh
```

Shell scripts are POSIX `sh`. `statusline.test.sh` renders `statusline.sh`
against fixture JSON and asserts both layouts, gauges, colors, and indicators.
`fit.test.sh` asserts `fit-line1.awk`'s width calculation and cut behavior
directly. `width.test.sh` verifies tty discovery, width refresh, caching, and
fallback behavior.

## License

[MIT](LICENSE)
