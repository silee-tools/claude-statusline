# claude-statusline

A width-independent, vertical-stack statusline HUD for
[Claude Code](https://code.claude.com). It renders location, the logged-in
Claude account, git branch, GitHub/AWS session indicators, the Claude Code
session id, context-window usage, rate limits, reasoning effort, and cost — all
in a single fixed layout.

```
17:14 ~/↪1/webapp/↪1/src  feature/PROJ-123-post-editor
dev@example.com gh@personal aws:✓
Opus 4.8 ▃ v2.8.0 ⧉ 3f9c1a20-7b4e-4d61-9a02-1c8e5f6b7d90
 ctx █████████████░░░░░░░ 68%
  5h █████████░░░░░░░░░░░ 47% ↺2h30m
  7d ████████████████░░░░ 83% ↺3d16h
cost 24h Opus $12 Sonnet $3 / 7d $42 / 31d $186
```

The statusline renders as one vertical stack regardless of terminal width. Lines
with no data are dropped entirely. The stack groups its rows by meaning:
location, then identity, then run metadata, then the usage gauges, then cost.

- **Line 1 (location)** — time (`HH:MM`), the current path, and the git branch
  (prefixed with the ` ` branch icon, no space before the name). The path
  collapses `$HOME` to `~`, keeps git-repo names and the current folder, and marks
  skipped segments as `↪N` (N = folders omitted).
- **Line 2 (identity)** — the logged-in Claude account email, `gh@<account>`, and
  `aws:<session>`. Each appears only when it has a value.
- **Line 3 (run)** — the model name and reasoning-effort indicator, then the
  Claude Code version and the session id (`⧉ <uuid>`, shown in full so it can be
  copied for cross-session reference). The branch icon and session marker need a
  Nerd Font to render; without one they show as `□`.
- **Lines 4–6 (ctx / 5h / 7d)** — the context-window usage bar and the 5-hour and
  7-day usage-limit bars, each on its own line so their fills compare at a glance.
  The rate bars also carry `%` and time-until-reset (`↺`). A rate line is dropped
  when its data is absent.
- **Line 7 (cost)** — today's per-model cost (`24h`), the rolling 7-day total, and
  the current-month total, separated by dim slashes.
- The `ctx`, `5h`, `7d`, and `cost` labels are right-aligned to one width, so the
  bars and amounts all start in the same column and the gauges line up vertically.

## Bars

Bars are 20 cells (one cell = 5%, floored); `█` is filled, `░` is empty. The
context bar and the rate bars share one coloring scheme: fill, empty track, and
`%` all follow a single color, bright by default, escalating to yellow then red
past a threshold. Thresholds are **40% / 70%** for the context bar (it warns
earlier) and **80% / 90%** for the rate bars.

## Reasoning effort

Effort is shown as a vertical ramp glyph plus a warm-gauge color:
`low ▁` (green) · `medium ▂` (lime) · `high ▃` (yellow) · `xhigh ▅` (orange) ·
`max ▇` (red). It is omitted when no effort information is available.

## Install

Requires [Claude Code](https://code.claude.com), a POSIX `sh`, and `awk`. `git`
powers the branch display. `curl` is optional: it refreshes the model pricing
table once a day from the public
[LiteLLM price table](https://github.com/BerriAI/litellm); without it (or if
the fetch fails), a built-in price table is used, so cost still works offline.
Cost (`24h` / `7d` / month) is computed directly from local Claude Code session
logs (`~/.claude/projects/**/*.jsonl`) and cached under
`${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline/`.

```shell
claude plugin marketplace add silee-tools/claude-statusline
claude plugin install claude-statusline@silee-tools
claude   # restart
```

On restart, the plugin's `SessionStart` hook wires `statusLine` in
`~/.claude/settings.json` automatically and refreshes the cost cache in the
background — no manual `settings.json` edit is needed. Cost is populated from the
second render onward.

### Dependencies

| Tool | Required? | Used for |
|---|---|---|
| `sh` (POSIX) | required | running the scripts |
| `awk` | required | parsing the statusline JSON and aggregating cost |
| `git` | required | the branch indicator |
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

The current login is read from
`${XDG_DATA_HOME:-$HOME/.local/share}/gh-prompt-user` (written by your shell
prompt). An unmapped login shows `gh@<login>`; an empty value shows `gh@---`;
color codes must be numeric.

### Claude account indicator

The logged-in Claude account email is read (read-only) from the
`oauthAccount.emailAddress` field of `${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json`,
Claude Code's own account state. Only that one field is scanned with `awk`, so
the large config file is not fully parsed on every render. The segment is
omitted when the file or the field is unavailable. Nothing is written to that
file.

### Customizing

The visuals live in `claude-statusline/scripts/statusline.sh`:

- **Bar thresholds** — `format_context_bar` (40/70) and `format_rate` (80/90).
- **Effort colors/glyphs** — `format_effort`.
- **Branch shortening length** — `max_words` in `shorten.sh`'s `shorten_branch`
  (default 4).

## Development

```shell
sh claude-statusline/tests/statusline.test.sh
```

Shell scripts are POSIX `sh`. The test suite renders `statusline.sh` against
fixture JSON and asserts the layout, bars, colors, and indicators.

## License

[MIT](LICENSE)
