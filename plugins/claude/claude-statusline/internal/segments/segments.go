// Package segments renders the Claude account indicator of the identity row.
package segments

import (
	"strings"

	"github.com/silee-tools/claude-statusline/internal/theme"
)

// Account renders the Claude account slot of the full layout from what internal/anchor
// resolved. Nothing here reads a Claude settings file.
//
//   - installed is false when the OTLP receiver never ran on this machine: the slot is
//     empty, because a permanent "?" would tell the reader nothing;
//   - an unknown account is a dim "?": no anchor says which account the session uses;
//   - a confirmed account, one an in-session /login named, is its email;
//   - an estimated account, the one the settings file held when the session began, is
//     its email behind a dim "~", because nothing shows the session's credentials are
//     that account's;
//   - either is followed by "?" when suspect, that is when the receiver looks stopped, the
//     anchor is of an earlier receiver generation, or the session's rate-limit window
//     changed under it.
func Account(installed bool, email string, estimate, suspect bool) string {
	if !installed {
		return ""
	}
	email = stripControl(email)
	if email == "" {
		return theme.Dim + "?" + theme.Reset
	}
	out := theme.Coral173 + email + theme.Reset
	if estimate {
		out = theme.Dim + "~" + theme.Reset + out
	}
	if suspect {
		out += theme.Dim + "?" + theme.Reset
	}
	return out
}

func stripControl(s string) string {
	return strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, s)
}
