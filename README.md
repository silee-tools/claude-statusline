# claude-statusline

A compact, three-row statusline HUD for [Claude Code](https://code.claude.com).
It renders location, the logged-in Claude account, git branch, GitHub/AWS
session indicators, the Claude Code session id, context-window usage, rate
limits, and reasoning effort — in three rows that never exceed 74 columns.

```
17:14 ~/↪1/webapp/↪1/src  feature/PROJ-123-post-editor
dev@example.com gh@personal aws:✓ v2.8.0 ⧉ 3f9c1a
ctx 68% Opus 4.8 ● 5h 47% ↺2h30m 7d 83%▲ ↺3d16h
```

The statusline always renders three rows and caps each at 74 display columns.
Rows with no data are dropped entirely. The rows group by meaning: location,
then identity and constants, then the usage gauges.

- **Row 1 (location)** — time (`HH:MM`), the current path, and the git branch
  (prefixed with the ` ` branch icon, no space before the name). The path
  collapses `$HOME` to `~`, keeps git-repo names and the current folder, and marks
  skipped segments as `↪N` (N = folders omitted). Path and branch share a
  66-column budget; when they exceed it each is capped at 33 columns, with the
  unused remainder handed to the other. Whatever still overflows is cut and
  marked with `…`. Cutting counts display columns, so a wide character (Hangul,
  CJK) is never split in half.
- **Row 2 (identity and constants)** — the logged-in Claude account email,
  `gh@<account>`, `aws:<session>`, the Claude Code version, and the session id
  (`⧉ <first 6 chars>`). Each appears only when it has a value.
- **Row 3 (gauges)** — context-window usage (`ctx`), the model name and
  reasoning-effort indicator, then the 5-hour and 7-day usage limits. Each rate
  gauge carries its percentage, a pace marker (`▲`) when usage runs ahead of the
  elapsed-time budget, and time-until-reset (`↺`). A rate gauge is dropped when
  its data is absent.
- The branch icon and session marker need a Nerd Font to render; without one
  they show as `□`.

## Gauges

Percentages are bright by default and escalate with usage: the context gauge
turns yellow at 40% and red at 70%; the rate gauges turn yellow at 80% and red
at 90%.

The `5h` and `7d` gauges also track a time-based pace budget. Over each window
the elapsed fraction defines how much you could spend and stay on pace. When
usage runs ahead of that budget a `▲` follows the percentage — yellow for a
small overshoot, red once it exceeds 15 percentage points. No marker means you
are on or under pace.

Costs are not displayed. The background cost cache is still refreshed, so
restoring the display later needs no new collection.

## Reasoning effort

Effort is shown with the same circle glyphs Claude Code uses in its session
header, plus a warm-gauge color: `low ○` (green) · `medium ◐` (lime) ·
`high ●` (yellow) · `xhigh ◉` (orange) · `max ◈` (red) · `ultracode ✦`
(magenta). It is omitted when no effort information is available.

## Install

Requires [Claude Code](https://code.claude.com), a POSIX `sh`, and `awk`. `git`
powers the branch display. `curl` is optional: it refreshes the model pricing
table once a day from the public
[LiteLLM price table](https://github.com/BerriAI/litellm); without it (or if
the fetch fails), a built-in price table is used. The statusline itself does
not display cost, but a per-model cost tally (`24h` / `7d` / month) is still
computed directly from local Claude Code session logs
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

- **Gauge thresholds** — `format_context` (40/70) and `format_rate` (80/90).
- **Effort colors/glyphs** — `format_effort`.
- **Branch shortening length** — `max_words` in `shorten.sh`'s `shorten_branch`
  (default 4).

## Development

```shell
sh claude-statusline/tests/statusline.test.sh
```

Shell scripts are POSIX `sh`. The test suite renders `statusline.sh` against
fixture JSON and asserts the layout, gauges, colors, and indicators.

## License

[MIT](LICENSE)
