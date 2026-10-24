# AGENTS.md

Guidance for AI agents and contributors working in this repository.

This repo holds the `claude-statusline` Claude Code plugin, published through a
marketplace catalog: a width-aware statusline HUD with a compact two-row layout
and a full layout of up to six rows. End-user documentation lives in
[README.md](README.md); this file covers how to change the code safely.

The plugin owns a directory under `plugins/claude` named after it, holding
`.claude-plugin/plugin.json`, `hooks/hooks.json`, `scripts/`, and `tests/`.
`hooks.json` is auto-discovered;
do not also declare a `hooks` field in `plugin.json` (double-registration errors
out).

## 문서·주석 작성

- 문서·주석·PR 본문에는 독자의 실행·판단에 필요한 현재 정보만 간결하게 씁니다.
  반복, 코드 재서술, 당연한 동작, 작업 경위와 폐기된 구현 설명은 생략합니다.
  상세 설명은 담당 문서에 모으고, 필수 절차·제약·검증 근거는 보존합니다.

## The render path is Go

`plugins/claude/claude-statusline` renders in one process: `cmd/statusline` reads
the payload on stdin and writes the rows, and `internal/` holds the packages it
composes.
`scripts/statusline.sh` stays as a shim that `exec`s that binary, so the command
already recorded in `settings.json` keeps working.

The module uses **the standard library only**. This is a distribution constraint,
not a preference: the binary is built on the user's machine, so a single external
module would make the first session need the network, and the statusline would
not come up where the network is absent or a proxy blocks it. Verify with
`GOPROXY=off go build ./...` — it fails rather than fetching.

The binary is not committed. `scripts/build-binary.sh` builds it once per plugin
version into
`${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline/bin/statusline-<version>-<GOOS>-<GOARCH>`
and writes that absolute path to `binary-path-<key>` beside it, which is the one
line the shim reads. The key is the plugin root's directory name — the version in
an installed copy, `claude-statusline` when the scripts run from this repository —
and the shim derives it from its own `$0` while the two hook scripts derive it from
`CLAUDE_PLUGIN_ROOT`. Splitting the pointer is what keeps two installed versions
apart: the shim is pinned in `settings.json` to one version's path while every
installed version runs its own `SessionStart`, so a single pointer had each version's
hook overwriting the line the pinned shim reads. 계정마다 설치 경로가 달라도 바이너리와 포인터는 공용이다. 다른 계정 설치와
동시 빌드를 보호하기 위해 빌드는 기존 바이너리를 자동 삭제하지 않는다.
The `SessionStart` hook detaches that build into the
background because the hook's timeout is 5 seconds and a cold build lands on it.

`cmd/claude-statusline-otlp` is the second binary: the receiver of Claude Code's
OpenTelemetry log events that gives each session's account to the statusline, with
the anchor rules in `internal/anchor`. `build-binary.sh` builds it beside the render
binary and publishes it by copy and rename to
`${XDG_DATA_HOME:-$HOME/.local/share}/claude-statusline/bin/claude-statusline-otlp`,
only when the version recorded there is lower. An equal version is left alone because
the receiver exits 75 when its file is replaced, so a needless replacement is a
restart. The compare, the copy and the version write run under a `mkdir` lock in that
directory, and the version is read again inside it: hooks of different versions run
concurrently, and without the lock a lower version could overwrite a higher one and
leave `.version` naming a binary that is not there. The receiver holds a `flock` on
`otel/receiver.lock` while it runs and the render path trusts an anchor only while that
lock is held, probed in three system calls and no child process: the kernel drops the
lock on any exit, so a stopped receiver is noticed without a write to the state
directory, which a heartbeat file needs. The script names no service:
starting and restarting the receiver is the supervisor's job, which keeps the source
publishable.

Two properties keep the port worth its while, so hold them when editing:

- The shim starts no child process. Computing the path per render with `uname`,
  or calling the build script, spends back the time the port saved.
- Read the clock once per render and pass that value down. Reading it per segment
  lets a second boundary fall between two of them and move a pace budget by a
  cell.

`statusInset` in `internal/render` is Claude Code's value: with `statusLine.padding`
unset it indents the status line by 2 and leaves the last 2 columns empty. Measure
it again when the Claude Code version changes: start `claude --settings
'{"statusLine":{...}}'` in a detached tmux window under an isolated `HOME` and
`CLAUDE_CONFIG_DIR`, have the command print an L-column ruler at several widths, and
read the widest ruler shown without `…`. 2.1.307: columns − 4, padding unset.

## Shell scripts: POSIX sh

Every remaining shell script is POSIX `sh` (`#!/bin/sh`). Executable entrypoints
use `set -eu`; shared helpers loaded via `.` do not force shell options on their
caller. Avoid bashisms:

- `[[ ]]` -> `[ ]` or `case`
- arrays (`arr=()`, `${arr[@]}`) -> positional params (`$@`) or string splitting
- `=~` / `BASH_REMATCH` -> `case` patterns, `expr`, or `sed`
- `${var,,}` / `${var^^}` -> `tr`
- `<<<` here-strings -> `printf '%s' "$var" | ...`
- `(( ))` -> `$(( ))` or `[ "$a" -gt "$b" ]`
- `function foo()` -> `foo()`

`local` and `$(...)` are used and assumed available.

## Testing

Run every suite from the repo root; the exit code is the gate, so a suite that
fails to start fails the run rather than reporting zero failures:

```shell
sh -c 'rc=0; for t in plugins/claude/*/tests/*.test.sh; do sh "$t" || rc=1; done; (cd plugins/claude/claude-statusline && go test ./...) || rc=1; exit "$rc"'
```

A suite that cleans up in an `EXIT` trap has to carry a completion flag, because
bash 3.2 — the `/bin/sh` on macOS — resets `$?` to zero on entering that trap. A
trap that only removes its temp directory therefore reports a `set -eu` abort as
a clean exit, and the gate above cannot tell an aborted run from a passing one.
Each such suite sets `completed=0` before registering the trap, sets
`completed=1` immediately before its final `[ "$fail" -eq 0 ]`, and forces a
non-zero status in the trap when the flag never reached one. A new suite that
registers a cleanup trap without that flag silently opts out of the gate.

A suite that touches state, data, cache or the publish path sets `HOME`,
`CLAUDE_CONFIG_DIR`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME` and
`XDG_CONFIG_HOME` to temporary paths, and refuses to start when one lies outside its
temp root. A Claude Code session exports `CLAUDE_CONFIG_DIR` and it wins over `HOME`,
so a `SessionStart` run that isolates only `HOME` rewrites the real `settings.json`;
a shell setup can export `XDG_DATA_HOME` and `XDG_STATE_HOME`, so isolating only
`HOME` would let a build publish over the live receiver and a render write the real
anchors. A call that forgets an override still lands in the temp root.

`statusline.test.sh` builds the binary, points the shim at it, and asserts both
layouts, gauges, colors, and indicators against fixture JSON. It fails outright
when that build fails, because a skipped build would report zero checks as a
pass. `shim.test.sh` asserts what the shim does with and without a binary and
that `build-binary.sh` is idempotent, never blocks session start, and leaves the
highest version published when publishers of several versions race.
`otlp.test.sh` starts the receiver on `127.0.0.1:0`, never a fixed port, posts
requests with `curl`, reads the account slot back through the shim, and stops the
receiver by the pid it recorded.
`statusline.test.sh` and `config-dir.test.sh` seed anchors without a receiver, so they
build `tests/testdata/lockholder` (a program that takes the same lock through
`anchor.LockReceiver`) and keep it running, as a live receiver would.
`json.test.sh` and `settings.test.sh` cover the awk parser and rewriter the
`SessionStart` hook still uses.

The Go tests carry the boundaries the shell suite only sees through whole-output
comparison: display width and cutting, terminal-width decisions, path and branch
shortening, the gh cache decision table, gauge thresholds and reset formatting.
`internal/shorten` pins both the plain shortening and the colored output, because
a table that reads only the surviving words still passes when the rule that paints
the repository and current segments blue is broken.

Follow Red -> Green: add a failing test before a behavior change, then make it
pass. Report the pass/fail counts when you change behavior.

Test fixtures must not contain real people, accounts, or secrets. Use
placeholder logins (e.g. `octocat`) and RFC 2606 reserved domains
(`@example.com`) where an address is needed.

## Versioning

Each plugin is loaded from a **version-pinned cache**, so any change that should
reach installed users needs a version bump. On every functional change:

1. Bump `plugins/claude/<plugin>/.claude-plugin/plugin.json` `version` (SemVer).
2. Set that plugin's entry `version` in `.claude-plugin/marketplace.json`
   to the same value.

Keep the two versions identical. Commits follow Conventional Commits
(`feat(...)`, `fix(...)`, `refactor(...)`, `chore(...)`, ...).

## The awk parser is not a duplicate

`scripts/hook-handler.sh` parses the hook payload and `settings.json` with
`scripts/json.awk`, and `tests/json.test.sh` covers it. It is the only
implementation of what it does, not a second copy of the Go parser, so it stays.

## Configuration is data, not code

The `gh@<account>` mapping is intentionally **not** in the source. It is read at
runtime from `${XDG_CONFIG_HOME:-$HOME/.config}/claude-statusline/gh-accounts`.
Do not hardcode account names, labels, or colors in the scripts — keep the source
publishable.
