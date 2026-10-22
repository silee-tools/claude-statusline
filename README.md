# claude-statusline

This repository publishes two Claude Code plugins through one marketplace,
`silee-tools`. The sections up to and including [Development](#development)
document `claude-statusline`; [stuck-resume](#stuck-resume) follows
them in its own section.

## claude-statusline

A width-aware statusline HUD for [Claude Code](https://code.claude.com). It
shows location, accounts, session state, context usage, rate limits, reasoning
effort without forcing the same layout onto every terminal.

At 80 columns or fewer, the compact layout uses up to two rows, each within
the detected width:

```text
feature/PROJ-123-post-editor gh@personal
ctx 68% Opus 4.8 ● 5h 47% ↺2h30m 7d 83%▲ ↺3d16h
```

At 81 columns or more, the full layout puts the version, the clock, the Claude
account, the session id, the location, and the gh and aws indicators on one first
row, followed by the three gauge rows:

```text
v3.1.0 17:14 dev@example.com ⧉ 11111111-2222-3333-4444-555555555555 ~/↪1/webapp/↪1/src feature/PROJ-123-post-editor gh@personal aws:✓
ctx █████████████░░░░░░░ 68% Opus 4.8 ●
 5h █████████░░░░░░░░░░░ 47% ↺2h30m
 7d ████████████████▓░░░ 83% ↺3d16h
```

When that row does not fit, the full layout breaks it before the path, down to
six rows (see [Layouts](#layouts)).

Rows with no data are omitted in either layout.

## Width selection

`CLAUDE_STATUSLINE_WIDTH` overrides automatic detection when it contains only
digits. Otherwise the statusline follows the parent process chain to a tty, up to
four levels, and asks that device for its current window size. It caches only the
tty path; the size is read again on every render so a terminal resize takes
effect on the next update. `COLUMNS` is intentionally ignored because an exported
value can stay stale after a resize.

Claude Code indents the status line by 2 columns and leaves the last 2 empty
(measured on 2.1.307 with `statusLine.padding` unset), so the widest row it shows
whole is the column count minus 4. A wider row is cut with `…`, not wrapped. The
full layout breaks its first row to fit that width.

The full layout is selected when width detection fails. This fallback keeps
all information visible when the available width is uncertain; with no width to
measure, the first row is never broken, and Claude Code cuts it with `…` if it is
wider than the window.

Two cases leave the first row cut at its right end. `statusLine.padding` narrows
the usable width by 2 columns per unit, which the layout does not know. And Claude
Code does not rerun the status line command when the window is resized, so
narrowing the window keeps the earlier output until the next update;
`statusLine.refreshInterval` (seconds) makes Claude Code rerun it periodically.

## Layouts

The compact layout has up to two rows, and a row with nothing to show is left
out:

- **Row 1 (branch and indicators)** contains the git branch, the gh slot
  (`gh@<account>` or `forgejo`, see [GitHub account indicator](#github-account-indicator))
  whenever it has something to show, and `aws:<state>` only when the login
  is not healthy (`aws:expired` or `aws:?`). An uncertain or failing gh state
  (`gh@x?`, `gh@x!`) is shown the same way. Indicators are never cut. The branch
  takes the columns they leave, with `…` marking a cut, and is dropped when
  fewer than 8 columns remain. With no branch, no gh slot, and a healthy aws
  login, the row is omitted.
- **Row 2 (gauges)** contains context usage, model, reasoning effort, and the
  5-hour and 7-day limits. Rate data that is absent is omitted independently.
  When the row is too wide, it drops the overpace duration `🔥…`, then the `7d`
  reset time, the `5h` reset time, and finally the model and effort.

The compact layout shows no clock, path, Claude account, version, or session id.
ANSI color codes count as zero width, and wide characters such as Hangul and CJK
are never split.

The full layout adds the clock, the path, the Claude account, the version, and
the full session id, shows every `aws:` state, and gives `ctx`, `5h`, and `7d`
separate 20-cell gauge rows. Its first row lists the version, the clock, the
Claude account, the session id, the path, the branch, gh, and aws in that order,
one space apart, and an item with nothing to show is skipped. When the row is
wider than the usable width (see [Width selection](#width-selection)), it breaks
before the path: the version through the session id stay on the first row and
the path, branch, gh, and aws take a second. When that second row is still too
wide, the path with the branch and the gh and aws indicators take a row each,
which makes six rows in all. A row of that last stage can still be wider than the
window, and Claude Code then cuts it with `…`.

The path collapses `$HOME` to `~`, preserves repository and current-directory
names, and marks skipped segments as `↪N`. The branch and session glyphs need a
Nerd Font; without one they may render as placeholder boxes.

## Gauges

Context usage turns yellow at 40% and red at 70%. Rate usage turns yellow at
80% and red at 90%, and on the `5h` and `7d` rows that color reaches the
percentage only — never the bar.

The bar on those two rows answers a different question: whether usage is ahead
of the elapsed-time budget. It carries two channels. A cell is `█` once spent
and `░` while it is not, and every cell from the budget position onward takes
the pace color whether spent or not. A window that keeps pace therefore draws
entirely in grey, and color appears only where usage has overrun the clock.
Small overshoots are yellow and overshoots of about 15 percentage points or
more are red. The comparison uses 20 five-point cells, so the boundary is
quantized rather than exact.

Keeping the two channels apart is what holds the boundary readable at high
usage. Were the bar painted with absolute severity as well, a window at 95%
would go red end to end, and a reader could no longer tell one that is nearly
spent but on schedule from one that is burning through its budget early.

The compact layout has no room for a bar and adds `▲` after the percentage
instead when usage is ahead of pace.

The `7d` pace budget advances continuously during local Monday-to-Friday
calendar days and pauses on Saturday and Sunday. The reset countdown remains
wall-clock based, and the `5h` pace budget continues to use elapsed time.

The `5h` and `7d` windows are shared between sessions of the same account through
`rate-limits.env` in the account cache described below. Whichever
session observes a window leaves it there, so a session that has just opened
shows both windows from its first render. The payload always wins over that
file: it is the only value that describes the account right now, and a stored
sample carries no observation time to be judged against. The file is drawn only
for a window the payload leaves out, and a window whose reset time has passed is
not drawn at all, because its usage no longer describes the current window.

## Reasoning effort

Effort is shown with the same circle glyphs Claude Code uses in its session
header, plus a warm-gauge color: `low ○` (green) · `medium ◐` (lime) ·
`high ●` (yellow) · `xhigh ◉` (orange) · `max ◈` (red) · `ultracode ✦`
(magenta). It is omitted when no effort information is available.

## Install

Requires [Claude Code](https://code.claude.com), a POSIX `sh`, `awk`, and
[Go](https://go.dev) 1.26 or newer. Go builds the render binary once on this
machine — see [First run](#first-run) below. `git` powers the branch display.
`ps` provides automatic terminal-width detection.

```shell
claude plugin marketplace add silee-tools/claude-statusline
claude plugin install claude-statusline@silee-tools
claude   # restart
```

On restart, the plugin's `SessionStart` hook wires `statusLine` in
`<config>/settings.json` automatically — no manual `settings.json` edit is needed.

### 계정별 설정과 캐시

`CLAUDE_CONFIG_DIR`가 비어 있거나 없으면 설정 디렉터리는 `$HOME/.claude`입니다.
지정하면 해당 경로의 `settings.json`을 사용합니다. 상대경로는
현재 작업 디렉터리 기준 절대경로로 만들고, 중복 `/`, `.`, `..`와 끝의 `/`를
정리합니다. 심볼릭 링크는 해석하지 않습니다. 기본 경로를 명시해도 기본 계정으로
취급합니다. 계정마다 같은 환경변수를 사용해 설치하고 실행합니다.
추가 계정을 설치하기 전에 기존 모든 계정의 플러그인을 먼저 5.5.1 이상으로 갱신합니다.

```shell
CLAUDE_CONFIG_DIR="$HOME/.claude-work" claude plugin marketplace add silee-tools/claude-statusline
CLAUDE_CONFIG_DIR="$HOME/.claude-work" claude plugin install claude-statusline@silee-tools
CLAUDE_CONFIG_DIR="$HOME/.claude-work" claude
```

기본 계정은 `${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline/`의 기존 캐시를
유지합니다. custom 계정은 그 아래 `accounts/<정규화한 config 경로의 SHA-256 전체>/`를
사용합니다. `cc-account.env`와 `rate-limits.env`가 분리됩니다.
기존 공유 캐시는 복사하거나 삭제하지 않습니다. Go 렌더러는 표준 라이브러리로
같은 hash를 계산합니다.

GitHub·AWS·Git·터미널 폭 캐시와 렌더 바이너리·포인터는 공용입니다.
다른 계정 설치와 진행 중인 빌드를 보호하기 위해 바이너리는 자동 삭제하지 않습니다.
따라서 사용하지 않는 판본의 바이너리가 남을 수 있습니다. 5.5.0 이하의 기존 빌드
스크립트는 공용 바이너리를 삭제할 수 있으므로 여러 계정에서 사용할 때는 각 계정의
플러그인을 5.5.1 이상으로 갱신해야 합니다.

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
| `awk` | required | parsing the hook JSON |
| `git` | required | the branch indicator |
| `ps` | optional | automatic terminal-width detection (falls back to the full layout) |
| `aws` (AWS CLI 2.32+) | optional | `aws login`'s session cache, read for the `aws:` session indicator: a cache whose `idToken` was refreshed within 15 minutes is `✓`; any other cache, including one without an `idToken` (newer AWS CLI), is settled by a background `aws sts get-caller-identity`, at most every 10 minutes (`✓` on success, `expired` on failure) |

## Configuration

### GitHub account indicator

The gh slot follows the `origin` remote of the repository the session is in, the
remote the shell prompt that writes the cache resolves the account from:

| Where the session is | Shows |
|---|---|
| origin host is `github.com` or an ssh alias `github.com-*` | `gh@<account>` and its state |
| origin host is listed in `forgejo-hosts` | `forgejo` only; no account |
| any other origin, or no origin | nothing |
| outside a git repository | `gh@<account>` of the default (active) account |

The host is the one in `scheme://[user@]host[:port]/path` or `[user@]host:path`,
compared case-insensitively. The Forgejo hosts are read from
`${XDG_CONFIG_HOME:-$HOME/.config}/claude-statusline/forgejo-hosts`, one host per
line, `#` starting a comment; without that file no host is Forgejo. The origin is read
from the repository's `.git/config` (following a worktree's or submodule's `.git`
file), without starting `git`, so `insteadOf` rewrites and included files are not
applied. While `GIT_DIR` or `GIT_WORK_TREE` is set the repository cannot be located,
so nothing is shown.

A GitHub login is mapped to a label and color. The mapping is not hardcoded — it is
read from `${XDG_CONFIG_HOME:-$HOME/.config}/claude-statusline/gh-accounts`, one entry
per line:

```
# <github-login>=<label>,<256-color-code>
octocat=personal,214
some-work-login=work,27
```

The login and its status are read from
`${XDG_CACHE_HOME:-$HOME/.cache}/gh-prompt/<repository root>` (written by your
shell prompt), where the file name is the physical repository root with each `/`
replaced by `%`; outside a repository it is `non-git`, which the prompt fills with
the active account of `gh auth status`. The cache is read only for
those two cases, so a record left for a Forgejo or other repository is never shown.
The segment is omitted when the file does not exist, which includes roots whose name
exceeds 240 bytes (Korean characters count 3 bytes each): the prompt writes no cache
for them. The file holds one tab-separated record:

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
`oauthAccount.emailAddress` field of `$HOME/.claude.json` for the default
configuration, or `<config>/.claude.json` for a custom configuration,
Claude Code's own account state. Only that one field is scanned, and the result
is cached until the file changes, so the large config file is not parsed in full
on every render. The segment is
omitted when the file or the field is unavailable. Nothing is written to that
file.

### Customizing

Colors, glyphs and value formatting live in
`plugins/claude/claude-statusline/internal/theme/`, and the two layouts are
assembled in `plugins/claude/claude-statusline/internal/render/`:

- **Gauge thresholds** — the numbers passed to `theme.GaugeColor`: 40/70 for
  context and 80/90 for the rate windows.
- **Effort colors and glyphs** — `theme.EffortGlyph`.
- **Branch shortening length** — `maxWords` in `internal/shorten` (default 4).
- **Layout switch point** — `compactAtOrBelow` in `cmd/statusline` (default 80).

A change here reaches the statusline only after the binary is rebuilt, which
happens on the next session start once the plugin version changes.

## Development

```shell
sh -c 'rc=0; for t in plugins/claude/*/tests/*.test.sh; do sh "$t" || rc=1; done; (cd plugins/claude/claude-statusline && go test ./...) || rc=1; exit "$rc"'
```

The render path is Go with no external modules; the remaining scripts are POSIX
`sh`. `statusline.test.sh` builds the binary, points the shim at it, and asserts
both layouts, gauges, colors, and indicators against fixture JSON.
`shim.test.sh` asserts what the shim shows with and without a binary and that the
build is idempotent. The Go tests cover display width and cutting,
terminal-width decisions, path and branch shortening, the account decision
table, and the gauge thresholds.

## stuck-resume

A `StopFailure` hook that resumes a turn something else cut short. Four causes
trigger it: the account hitting its 5-hour or 7-day usage limit, the login
expiring mid-turn, and the two transient API failures — the service being
overloaded or returning a server error. In every case the hook waits, then wakes
the model with a short prompt naming the cause, so the session picks the work
back up without anyone typing "continue".

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
matches only the `rate_limit`, `authentication_failed`, `server_error`, and
`overloaded` errors, so no other stop reason triggers it.

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
`rate_limit` against a usage limit, `authentication_failed` when the login
expired, which is the stop that shows "Login expired · Please run /login", and
`server_error` or `overloaded` when the API itself is briefly unavailable. The
hook entry sets `asyncRewake`, so the command runs in the background while the
session sits idle.

The hook follows six steps. First, the `StopFailure` hook registers its session and cause in shared state on the same machine. Second, a new session becomes eligible for one initial probe after the starting delay has elapsed from its registration time. Third, after a failed probe, the global delay doubles from its starting value and stops at a maximum of 480 seconds. Fourth, if the probe produces no result, another waiting session takes over at the next scheduled time. Fifth, when the current probe session emits `Stop`, every waiting hook exits immediately with code 2. Sixth, a hook that reaches its own budget without being given a turn probes anyway rather than waiting to be killed.

The hook does not read login state, but for `rate_limit` it reads the latest structured `resetsAt` value from the transcript and then falls back to the official reset time in `last_assistant_message`; only when both are unavailable does it use the three-hour deadline. A new turn that fails again registers the failure and follows the next global backoff interval. The hook does not poll while waiting, so it makes no network request until a scheduled probe is due.

The hook writes a short cause-specific prompt to **stderr** and exits with code 2 — the code that tells Claude Code to wake the model. Text on stdout is not injected.

### Settings

These settings apply to all local sessions participating in one global retry episode. The first hook to register an episode fixes the starting delay and probe cap for that episode; later sessions do not replace them.

| Variable | Default | Meaning |
|---|---|---|
| `CLAUDE_RESUME_WAIT_SECONDS` | `30` | first retry delay, minimum spacing before recovery, and exponential-backoff base from 1 through 480 seconds; the maximum delay is 480 seconds |
| `CLAUDE_RESUME_MAX_ATTEMPTS` | `0` | maximum serialized probes before recovery in one global episode; `0` leaves the error deadline as the only cap, and a successful broadcast is never limited |
| `CLAUDE_RESUME_HOOK_BUDGET` | `3540` | seconds a waiting hook may live before it probes without a turn; a value of 480 or less, or a non-integer, reads as the default |
| `CLAUDE_RESUME_STATE_DIR` | `${XDG_STATE_HOME:-$HOME/.local/state}/stuck-resume` | shared state for all local sessions |

The variable names still read `CLAUDE_RESUME_` rather than the plugin name, so a
configuration that already sets them keeps working across the rename.

The `server_error`, `overloaded`, and `authentication_failed` causes retry until three hours after their first failure in the episode. For `rate_limit`, the deadline is one hour after the reset time when a structured reset time or a reset time in the error message is available; when neither is available, the deadline is three hours after the first failure. When several causes are active, the latest cause deadline is used, and repeating an existing cause does not extend its deadline. A probe at or after the global deadline exits 0 without waking the session.

The plugin does not inspect or change Claude Code's `autoContinueAtUsageLimit` setting, so Claude Code's own automatic resume and this plugin's resume may overlap.

A deadline can sit hours — for a weekly usage limit, days — beyond the `timeout` in
`hooks/hooks.json` (3600 seconds), and Claude Code fixes a killed hook's exit code at
143, which injects nothing and re-registers nothing. So a waiting hook watches its own
budget: `CLAUDE_RESUME_HOOK_BUDGET` seconds after it registers, it stops waiting for a
turn and wakes its session anyway, leaving the active slot alone. If that turn fails
again, the new `StopFailure` registers a hook with a fresh budget, and the retry loop
survives to the deadline no matter how far away it is.

Keep the budget below the `timeout` and above the 480-second maximum backoff. The two
values live in different files and the script cannot read its own configured timeout,
so changing one means changing the other.

### Limits

Resuming needs a live interactive session. Under `claude -p` the process exits
before the background hook finishes, so nothing is resumed.

No trigger has been exercised against a real usage limit, a real expired login,
or a real API outage. The resume mechanism was verified with a stand-in `Stop`
hook, the four matcher values come from Claude Code's own list of `StopFailure`
error values, and the rest is covered by injecting hook input into `resume.sh`
directly.

## License

[MIT](LICENSE)
