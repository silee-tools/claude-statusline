# AGENTS.md

Guidance for AI agents and contributors working in this repository.

This repo is a single Claude Code plugin, `claude-statusline`: a
three-row statusline HUD capped at 74 display columns. End-user documentation
lives in [README.md](README.md); this file covers how to change the code
safely.

## Structure

```
.
├── .claude-plugin/marketplace.json   # marketplace catalog (name: silee-tools)
├── README.md                         # end-user docs
├── LICENSE                           # MIT
└── claude-statusline/                # the plugin
    ├── .claude-plugin/plugin.json    # plugin manifest (name, version, ...)
    ├── hooks/hooks.json              # SessionStart hook (auto-discovered)
    ├── scripts/
    │   ├── statusline.sh             # stdin JSON -> rendered statusline
    │   ├── shorten.sh                # path/branch shortening helper
    │   ├── fit-line1.awk             # row-1 path/branch -> width-capped text
    │   ├── hook-handler.sh           # cost refresh + auto-setup
    │   └── refresh-cost.sh           # session log aggregation -> cost cache, background
    └── tests/
        ├── statusline.test.sh        # fixture-driven render tests
        └── fit.test.sh               # fit-line1.awk width and cut assertions
```

`hooks.json` is auto-discovered; do not also declare a `hooks` field in
`plugin.json` (double-registration errors out).

## Shell scripts: POSIX sh

Every shell script is POSIX `sh` (`#!/bin/sh`). Executable entrypoints use
`set -eu`; shared helpers loaded via `.` do not force shell options on their
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

```shell
sh claude-statusline/tests/statusline.test.sh
```

The suite renders `statusline.sh` against fixture JSON and asserts layout,
gauges, colors, and indicators. Follow Red -> Green: add a failing test before a
behavior change, then make it pass. Report the pass/fail counts when you change
behavior.

Test fixtures must not contain real people, accounts, or secrets. Use
placeholder logins (e.g. `octocat`) and RFC 2606 reserved domains
(`@example.com`) where an address is needed.

## Versioning

The plugin is loaded from a **version-pinned cache**, so any change that should
reach installed users needs a version bump. On every functional change:

1. Bump `claude-statusline/.claude-plugin/plugin.json` `version` (SemVer).
2. Set the matching plugin entry `version` in `.claude-plugin/marketplace.json`
   to the same value.

Keep the two versions identical. Commits follow Conventional Commits
(`feat(...)`, `fix(...)`, `refactor(...)`, `chore(...)`, ...).

## Configuration is data, not code

The `gh@<account>` mapping is intentionally **not** in the source. It is read at
runtime from `${XDG_CONFIG_HOME:-$HOME/.config}/claude-statusline/gh-accounts`.
Do not hardcode account names, labels, or colors in the scripts — keep the source
publishable.
