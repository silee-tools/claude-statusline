# claude-statusline

This repository publishes the `claude-statusline` Claude Code plugin through the
marketplace `silee-tools`.

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

Each session keeps the `5h` and `7d` windows it last saw in its own file,
`${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline/rate-limits/<session_id>.env`.
The payload always wins over that file: it is the only value that describes the
account right now, and a stored sample carries no observation time to be judged
against. The file is drawn only for a window the payload leaves out, and a window
whose reset time has passed is not drawn at all, because its usage no longer
describes the current window. A session never draws another session's window,
since sessions of one config directory can run on different accounts, and a file
written by another process or before another login is not drawn either: a
conversation that a new process resumes shows no window until Claude Code sends one
(see [Claude account indicator](#claude-account-indicator)). A write removes the files
of sessions idle for two days and the oldest beyond 2,000.

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

상태줄의 계정 칸은 설정 디렉터리가 아니라 세션별로 정해집니다([Claude account indicator](#claude-account-indicator)).
한도 캐시도 세션별 파일이고, GitHub·AWS·Git·터미널 폭 캐시와 렌더 바이너리·포인터는 공용입니다.
다른 계정 설치와 진행 중인 빌드를 보호하기 위해 바이너리는 자동 삭제하지 않습니다.
따라서 사용하지 않는 판본의 바이너리가 남을 수 있습니다. 5.5.0 이하의 기존 빌드
스크립트는 공용 바이너리를 삭제할 수 있으므로 여러 계정에서 사용할 때는 각 계정의
플러그인을 5.5.1 이상으로 갱신해야 합니다.

5.10.0부터 `cc-account.env`, 공용 `rate-limits.env`, `accounts/<해시>/`를 읽거나 쓰지 않습니다.
자동으로 지우지 않으므로 필요하면 직접 지웁니다.

```shell
rm -f "${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline/cc-account.env" \
      "${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline/rate-limits.env"
rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline/accounts"
```

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

The same hook builds the OTLP receiver (`claude-statusline-otlp`, see
[Claude account indicator](#claude-account-indicator)) the same way and publishes it
to `${XDG_DATA_HOME:-$HOME/.local/share}/claude-statusline/bin/claude-statusline-otlp`,
a path that does not move with the plugin version. It copies the build over that
path through a rename and records the version in `claude-statusline-otlp.version`
beside it. A build is published only when its version is the same as or higher than
the recorded one (compared as numbers, 5.10.0 above 5.9.0), and a version already
published is left alone, because the receiver restarts when its file changes. A
failed build or publication leaves the render binary working and the session start
untouched.

### Dependencies

| Tool | Required? | Used for |
|---|---|---|
| `go` 1.26+ | required | building the render binary once per plugin version |
| `sh` (POSIX) | required | the statusline shim, the session hook, and the background jobs |
| `awk` | required | parsing the hook JSON |
| `git` | required | the branch indicator |
| `ps` | optional | automatic terminal-width detection (falls back to the full layout) |
| a supervisor for `claude-statusline-otlp` | optional | keeping the receiver running; without it the account slot stays empty (see [Claude account indicator](#claude-account-indicator)) |
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

The payload carries no account, and the account in `<config>/.claude.json` is the one
the last session wrote, not the one each session uses: sessions of one config
directory can run on different accounts, and a `/login` in one session changes the
file for all of them. The slot is therefore filled from Claude Code's OpenTelemetry
log events, kept per session by a small local receiver, `claude-statusline-otlp`.
Neither `.claude.json` nor `oauthAccount` is read.

| Slot | Meaning |
|---|---|
| `a@example.com` | confirmed: a `/login` inside this session named the account, and the process that runs the session is known |
| `~a@example.com` | estimate: the account the settings file held when the session began; the file is shared by every session of the config directory and the session's credentials may belong to another account. A `/login` anchor shows as an estimate too while the running process cannot be found, because the anchor may then belong to an earlier process of the same conversation |
| `a@example.com?`, `~a@example.com?` | may have changed unseen: no ready receiver holds the live lock (it stopped, is still starting, or the lock cannot be told), the receiver listens somewhere other than `127.0.0.1:14318` or `CLAUDE_STATUSLINE_OTLP_ADDR`, the receiver's heartbeat is older than 120 seconds (it hangs), the anchor was stored before the receiver's current generation or by another run than the one that holds the lock (it may have missed a `/login`), or a rate-limit window of the session has differed from its baseline for over a minute before the baseline window ended |
| `?` | the receiver runs but nothing says which account this session uses |
| *(empty)* | the receiver never ran on this machine (`otel/sessions` does not exist) |

The compact layout shows no account and reads none of this.

**What counts.** Per session id the receiver keeps one anchor, from these events only:
a start event (`plugin_loaded`, or `managed_settings_resolved` unless its
`managed_settings.trigger` is `change` or `refused`) sets it when the session has none, as
an estimate; a `managed_settings_resolved` with `trigger=startup`, which a process sends as
it starts, also replaces an older anchor, because that process is the one the session runs
in now; a successful `auth` event with `action=login` replaces the anchor with the new
account, confirmed; `action=logout` clears it. An event older than the stored anchor is
dropped. The email of any other event is never taken as the session's account, because it
is whatever the settings file holds at that moment (the `user_prompt` that opens the session
id `/clear` creates is one); it is only compared with the stored anchor. An anchor of an
earlier generation is stamped with the current generation again by the next event of its
session whose email is the anchor's, and keeps its account, kind (an estimate stays an
estimate) and time; an event with another email changes nothing, so the `?` stays. Events
carry no process id, and every email in them comes from the settings file, so only a
`/login` made inside the session proves which account its credentials belong to.

**`/clear`.** Claude Code keeps `<config>/sessions/<pid>.json` for each running
process, and `/clear` changes only its `sessionId`. The statusline records the anchor
under the process (`pids/`) and the new session id takes it over, again after a
second `/clear`, and after a `/login` that arrived between two renders. A render that
finds no anchor yet records only its session id there, a seed file, and rewrites it only
when the id changes. The first render under the new id settles the carry once: if the old
id's anchor is still the one the process carried (same account, kind and time), the
process keeps it for good; if it has changed, whose event changed it cannot be told
(another process may have resumed the old id), so the process shows `?` until it logs in.

**`--resume` and `--continue`.** `claude --resume <id>` sends its start events under the
resumed id, so the new process's startup event replaces what an earlier process left
under it: the session shows the account the settings file held when the new process
started, as an estimate, whatever the earlier anchor was. `claude --continue` sends them
under a throwaway session id that nothing ties to the process, and anchors of other session
ids are never borrowed on the strength of timing, because any process of any config
directory could have written them: that session shows `?` until it logs in. A conversation
resumed inside a running process (`/resume`) sends no start event under the resumed id; it
takes the anchor the process carries, as `/clear` does. A process that has found no anchor
yet (its first render usually comes before its start event reaches the receiver) carries
that of the session id it rendered last once that anchor exists and began after the process
did; otherwise the session shows `?`. A `claude --resume <id>` that fails because the
conversation does not exist still sends its start events under that id, with the account
the settings file of the config directory it ran in holds.

**Which process.** A `sessions/<pid>.json` names a process only while that process runs
(`kill(pid, 0)`): a kill, a crash or a reboot leaves the file behind, and a resumed
conversation must not take the account or the rate-limit windows of the process that
died. The statusline's parent (Claude Code) is trusted first, when its own file names the
session; then the process a session's ref names, if it still runs; then, among the
running processes whose files name the session, the one that started last. A pid that an
unrelated process has reused counts as running; the first and last rules narrow that
without closing it.

**Rate-limit windows.** The windows a session saw are kept per *boundary*: the process
that runs it and the time of its last in-session login or logout. A conversation that a
new process resumes, or that has logged in again, draws none of the windows the
previous boundary saw. Where the process cannot be told, nothing is kept.

**Limits to know.**
- A start anchor is the account the settings file held when the session began. A
  session that shows "Not logged in" carries it too, which is why it is only an estimate.
- Restarting the receiver (a new plugin version replaces it, or the supervisor restarts
  it after a failure) starts a new generation, so every session shows `?` behind its
  email until the session sends an event whose email is the anchor's, which stamps the
  anchor with the new generation; if the settings file names another account, the `?` stays
  until a `/login` or a `--resume` replaces the anchor. Events sent while the receiver was
  down are lost, and a `/login` among them would otherwise go unseen. A generation is a
  counter, not a time, so correcting the system clock cannot make a stored anchor look
  current. A session that shows its account from the copy `/clear` or `/resume` made keeps
  the generation of that copy, so after a restart it shows `?` until it logs in.
- A failed `claude --resume <id>` run in another config directory (see above) replaces the
  anchor of an open session with that id by the email in that directory's settings file:
  the latest startup event wins.
- The statusline looks at the live lock's path again after it has read the lock, and a path that
  no longer leads to that file counts as no receiver. A change after that look, within the same
  render, is not seen: that one render still shows the account as confirmed. A path that is still
  changed at the next render gets `?` behind the account, and the replaced receiver exits 1 if it
  finds the path changed at its next heartbeat tick or write. Only the path at the moment of each
  look counts: a file moved away and put back before then is trusted again.
- Two Claude Code processes that run the same session id at the same time share one anchor.
- A conversation resumed with `/resume` shows `?` when the process had not rendered under
  its start id before the `/resume`, or when that id's start anchor had not reached the
  receiver by the first render under the resumed id. If another process of the same config
  directory resumed the start id and anchored it after this process began, the first
  process takes that anchor.
- A session that quietly takes over another session's credentials at a token refresh
  emits no event. The only trace is a rate-limit window changing before it ends, which
  adds `?`; the account is never corrected from it. Both the five-hour and the seven-day
  window are watched (`fingerprintWindows` in `cmd/statusline`); a window that has ended
  starts a new baseline.
- A session started before the variables below are set shows `?` until it restarts.
- Only start events make an anchor, so a session whose start events never reached the
  receiver (it started before the receiver ran, or `--continue`) shows `?` until it logs in or
  is opened with `--resume`. A session with telemetry off sends nothing, a `/login` included,
  and keeps `?`.
- The account appears at the first render after its events reach the receiver
  (the export interval below is 1 second). `statusLine.refreshInterval` (seconds) makes
  Claude Code rerun the command periodically, so a new session does not wait for its
  first response.

**Wiring.** Claude Code must export its log events to the receiver. Set these in its
environment (settings `env` block or the shell):

```shell
CLAUDE_CODE_ENABLE_TELEMETRY=1
OTEL_LOGS_EXPORTER=otlp
OTEL_METRICS_EXPORTER=none
OTEL_EXPORTER_OTLP_PROTOCOL=http/json
OTEL_EXPORTER_OTLP_LOGS_ENDPOINT=http://127.0.0.1:14318/v1/logs
OTEL_LOGS_EXPORT_INTERVAL=1000
```

Leave the content-logging variables (`OTEL_LOG_USER_PROMPTS` and similar) and
`OTEL_EXPORTER_OTLP_COMPRESSION` unset: the receiver answers a gzip body with 415.

The statusline expects the receiver at `127.0.0.1:14318`. For another port, start the receiver
with that `-addr` and give the statusline `CLAUDE_STATUSLINE_OTLP_ADDR=127.0.0.1:<port>` in the
same environment (not an `OTEL_*` name: Claude Code does not pass those on to it).

**The receiver.** Run the published `claude-statusline-otlp` under a supervisor that
restarts it after a non-zero exit. It listens on `127.0.0.1:14318` only (`-addr` must be
a loopback IP literal), serves `POST /v1/logs` with `Content-Type: application/json` and
a body of at most 1 MiB, and answers `200 {}`; when it could not store a record, or the
body did not arrive (the connection ended before the `Content-Length` did, or the 60-second
read limit for the whole request passed first), it answers `503` with `Retry-After: 5`,
which the exporter retries. The limit for reading the headers is 30 seconds. It stores no
event and reads only `session.id`, `user.email`, `event.name`, `action`, `success`,
`managed_settings.trigger` and the event time of each record; stderr says what happened
(start, stop, failure kinds), never a value. Exit
codes: 0 after SIGINT or SIGTERM; 75 when the file at its own path was replaced (it
checks every 30 seconds), so the supervisor starts the new build; 1 when the address is
not loopback, the port cannot be bound, the state directory cannot be prepared or read,
another receiver holds the lock, or a lock file is removed or replaced under it (see below).
While it runs it holds two `flock`s. The
start lock (`otel/receiver.lock`) keeps a second receiver out and is taken before the receiver
touches any state; the live lock (`otel/receiver.live`) is taken last, once the generation and
the heartbeat are written, and the statusline trusts an anchor only while it finds the live lock
held. Until then, whatever the previous run left behind is not trusted, so there is no moment of
a start in which an earlier run's anchor passes as current. The kernel drops the locks when the
process ends however it ends (exit 0, 75, a crash, SIGKILL), so a stopped receiver is noticed at
once and needs no write to the state directory to say so, which a failing start may not be able
to make. Each start makes a random run id. It writes the generation file naming that run, then the
heartbeat, and only then takes the live lock, which it gets only over state that is its own; it
puts the run and the address it listens on into the live lock's file through the file it holds
(replacing the file would cost it its own lock), and every anchor it stores carries the run
(`run=`). A number cannot say whose count it is, because two receivers can arrive at the same one,
so the statusline reads the run from the lock it found held and trusts an anchor only when the
anchor's run and the generation file's run both are that run, the anchor's generation is not below
the file's, and the receiver listens where the sessions send their events: `127.0.0.1:14318`, or
the `host:port` of `CLAUDE_STATUSLINE_OTLP_ADDR`. Claude Code does not pass its `OTEL_*` settings on to
the status line command (measured on 2.1.310, for both settings `env` and the shell), so the address
cannot be read from them; a setting that is not an IP literal and a port matches no receiver. A
missing lock file, a lock nobody holds, a lock file that is not a regular file (a FIFO
or a link left in its place: the statusline opens it without blocking and without following a
link), a lock file found replaced or removed when the probe looks at its path again and a lock
that cannot be probed all count as no receiver, so the statusline puts `?` behind the account. The state directory has to
be on a filesystem that supports `flock` (a local one); where the lock cannot be taken the receiver does not start. Before it stores an
anchor or writes the generation or the heartbeat, and on every heartbeat tick, the receiver
checks that its locks are still on the files at their paths; if a lock file was removed or
replaced (which would let a second receiver lock a new file and write the same state) it
writes nothing more and exits 1, and the supervisor's restart creates a fresh one. The check
and the write are not one step: a receiver held up between them writes once more after another
has taken over. That write carries the replaced receiver's run, so the statusline does not trust
it, and the new receiver's next beat puts the generation file back if the write changed it. A
start also replaces a lock file that is a FIFO, a link or an empty directory. The
receiver touches the heartbeat every 30 seconds, except while it cannot store an anchor, which
is what shows a receiver that hangs (it still holds the locks): the heartbeat older than 120
seconds puts `?` too. A failed write moves the receiver to the next generation (`otel/generation`, a counter) and
withholds the heartbeat until a probe write succeeds. Every anchor carries the generation
it was stored under (`gen=`), and the statusline puts `?` behind an anchor of an earlier
generation than the file names. The generation the recovery writes is the one of the last
loss, so an anchor stored by the exporter's retry in between is not doubted. A request
refused as oversized (413), unreadable (400) or compressed (415 for its `Content-Encoding`),
or whose body did not arrive (503), is a batch dropped whole, a `/login` with it, so each
moves to the next generation too, whoever sent it: a process that can post to the receiver
could also write the anchors, so a false alarm costs an extra `?`. A request of another
media type (415, for example protobuf) is not counted: Claude Code is set to JSON, so it is another exporter's, and one
that kept sending would hold every account in doubt. A generation that cannot be written
counts as a loss that is not recorded yet, so the heartbeat stays withheld until it is.
Why the generation rose is in `otel/losses` (see Files): one line for each of the last 20
losses, with the kind of failure and its cause, never what the request carried. A start
moves the generation without a line there.
A start takes the start lock after it binds the port and before it touches any state: a
receiver that finds either lock held (one on another port, or one whose start lock file was
removed) exits 1 and leaves the running one's files alone. A receiver on another port that holds
the locks is not trusted either, since the statusline expects the address above: every account
shows `?` while the receiver for the right port exits 1 at each restart, and `cat otel/receiver.live`
says which receiver holds the lock. To run one by hand on another port, point `XDG_STATE_HOME` at a
temporary directory. It then removes the generation file
(a damaged or unreadable one must not be counted from) and the heartbeat, writes its own, and
takes the live lock last. Every start moves to the next generation, past the highest number
in the stored anchors, so what an earlier run stored is doubted whatever the clock reads and
whether or not a generation file survived (a damaged one is replaced the same way). A start
answers only when it has seen all of that state: a directory or file that is missing counts as
empty, an entry that is not a regular file (a directory, a link) is skipped as the reader skips it, but one that cannot be listed
or read makes the start give up with exit 1, which the supervisor retries every 10 seconds
(about 4 ms of CPU a time, no log). The statusline shows `?` throughout, and the receiver
starts once the cause is gone. One number bounds everything: the generation file, the number
in an anchor and what the receiver writes stay within `MaxGeneration` (2^62), a start whose
state is inside the last 2^40 of it gives up, and the receiver stops counting losses at the
bound. An anchor or generation file that someone planted at that end of the range therefore
keeps the start from succeeding until it is removed. A `gen=` that is not a number in range counts as generation
0, so the anchor is doubted and does not raise the count; the receiver never records a
generation that is not positive. At start and
then hourly it removes what is past retention. Where stderr goes, and how long it is
kept, is the supervisor's setting.

**Files.** State files are kept 30 days with at most 2,000 files in each of `otel/sessions`, `pids/` and `fingerprints/`. The receiver prunes all three at start, hourly and after each write, and a reader ignores an anchor older than 30 days even when nothing pruned it (the cache and data rows below say their own). Both programs write a state file by renaming a temporary file over it, so the statusline reads one only as a regular file, opened without blocking and without following a link: a FIFO, a link or a directory in the place of an anchor, the generation file, a pid file, a rate-limit cache or a fingerprint baseline is no state, and cannot hold the render. Every other state, cache or config file the render reads gets the same non-blocking, regular-file-only read, so a FIFO or a device in its place reads as absent (the receiver lock files are opened by the same rule in `internal/anchor`; the tty device is opened for its window size and is not a file read). The statusline's own cache files (`git-branch.env`, `tty-path.env`, `aws-check`, the agent-status snapshots) are read without following a link. Files that someone else writes or places (the gh prompt cache, `gh-accounts`, `forgejo-hosts`, git's `HEAD`, `config` and `.git` pointer, the aws login cache) are read through a link, which a dotfile manager may have put there, but the link must end on a regular file; a link to a FIFO reads as absent too. The caches the statusline writes at a path it also reads (`git-branch.env`, `tty-path.env`, `aws-check`) are replaced by renaming a temporary file named for the process over them, which turns a planted FIFO into a regular file and leaves a FIFO at any other name alone.

| Path | Written by | Holds | Kept |
|---|---|---|---|
| `${XDG_STATE_HOME:-$HOME/.local/state}/claude-statusline/otel/sessions/<session.id>.env` | receiver | email, kind, event time, time the receiver stored it, generation and run it was stored under (0600) | 30 days, 2,000 files |
| `.../otel/receiver.lock`, `.../otel/receiver.live` | receiver | the start lock (empty) and the live lock, `flock`s it holds while it runs; the live lock's file holds `run=` and `addr=` | two files |
| `.../otel/heartbeat` | receiver | its mtime | one file |
| `.../otel/generation` | receiver | its current generation number (one more than before at each start and each loss), then `run=` | one file |
| `.../otel/losses` | receiver | one line for each of the last 20 losses: time (`ts`, unix ms), the generation it reached, `kind`, `cause` and the `Content-Length` (-1 when unknown), never request content (0600); the statusline does not read it | one file of about 2 KB; the receiver replaces the whole file at each loss and removes it at start; no rotation |
| `.../pids/<pid>-<startedAt>.env`, `.../pids/session-<id>.ref` | statusline | the anchor a process carries (until it has one, only the session id it last rendered), which pid file a session uses | 30 days, 2,000 files |
| `.../fingerprints/<session_id>.env` | statusline | the baseline of the watched rate-limit window | 30 days, 2,000 files |
| `${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline/rate-limits/<session_id>.env` | statusline | the windows the session last saw, and the boundary they were seen under | 2 days after the last write, 2,000 files |
| `${XDG_DATA_HOME:-$HOME/.local/share}/claude-statusline/bin/claude-statusline-otlp{,.version}` | `build-binary.sh` | the published receiver | replaced by the same or a higher version, never deleted |
| `${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline/bin/claude-statusline-otlp-<version>-<os>-<arch>` | `build-binary.sh` | the built receiver | never deleted, like the render binary |

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
build and the receiver's publication are idempotent. `otlp.test.sh` starts the receiver
on a temporary loopback port, posts log requests with `curl`, and reads the account
slot back through the shim. The Go tests cover display width and cutting,
terminal-width decisions, path and branch shortening, the anchor rules, the receiver's
handler, and the gauge thresholds.

A suite that touches state, data or cache points `HOME`, `CLAUDE_CONFIG_DIR` and every
`XDG_*` variable at a temporary directory, so it never reaches the receiver's published
path or the state directories of the machine it runs on.

## License

[MIT](LICENSE)
