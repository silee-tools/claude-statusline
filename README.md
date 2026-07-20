# claude-statusline

A width-independent, vertical-stack statusline HUD for
[Claude Code](https://code.claude.com). It renders location, git branch,
GitHub/AWS session indicators, context-window usage, rate limits, reasoning
effort, and cost — all in a single fixed layout.

```
17:14  ~/↪1/webapp/↪1/src
(feature/PROJ-123-post-editor) gh@personal aws:✓
ctx  █████████████░░░░░░░ 68%        | v2.5.0 Opus 4.8 ▃
5h   █████████░░░░░░░░░░░ 47% ↺2h30m | 7d ████████████████░░░░ 83% ↺3d16h
cost 24h Opus $12 Sonnet $3          | 7d $42 31d $186
```

The statusline renders as one vertical stack regardless of terminal width. Lines
with no data are dropped entirely.

- **Line 1** — time (`HH:MM`) and the current path. The path collapses `$HOME`
  to `~`, keeps git-repo names and the current folder, and marks skipped
  segments as `↪N` (N = folders omitted).
- **Line 2** — shortened git branch, `gh@<account>`, and `aws:<session>`. Each
  appears only when it has a value.
- **Line 3 (ctx)** — context-window usage bar and `%`, then, right of the `|`,
  the Claude Code version, model name, and reasoning-effort indicator.
- **Line 4 (rate)** — the 5-hour (`5h`) and 7-day (`7d`) usage-limit bars, each
  with `%` and time-until-reset (`↺`), joined on one line by `|`.
- **Line 5 (cost)** — today's per-model cost (`24h`), then, right of the `|`,
  rolling 7-day and current-month totals.
- The `ctx`, `5h`, and `cost` lines auto-align so their `|` columns line up.

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

Requires [Claude Code](https://code.claude.com). `jq` is required; `bun` +
[`ccusage`](https://github.com/ryoppippi/ccusage) are optional (for cost).

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
| `jq` | required | parsing the statusline JSON |
| `bun` + `ccusage` | optional | cost figures (`24h` / `7d` / month) |
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
