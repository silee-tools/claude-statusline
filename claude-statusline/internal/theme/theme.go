// Package theme holds the colors, glyphs and value formatting both layouts share.
package theme

import (
	"fmt"
	"strings"
)

// ANSI sequences, byte for byte the ones scripts/statusline.sh declared.
const (
	Esc      = "\033"
	Dim      = "\033[2m"
	Green    = "\033[32m"
	Yellow   = "\033[33m"
	Red      = "\033[31m"
	Magenta  = "\033[35m"
	Cyan     = "\033[36m"
	Blue     = "\033[34m"
	Amber214 = "\033[38;5;214m"
	Lime     = "\033[38;5;148m"
	Grey240  = "\033[38;5;240m"
	Coral173 = "\033[38;5;173m"
	Reset    = "\033[0m"
)

// Branch and session glyphs, kept as code points so an editor cannot mangle them.
// BranchGlyph is Powerline U+E0A0 and SessionGlyph is U+29C9; both need a Nerd Font.
const (
	BranchGlyph  = ""
	SessionGlyph = "⧉"
)

// Cells is the bar length both the context and the rate gauges draw.
const Cells = 20

// NoBudget means the caller could not compute a pace budget, which is a different
// state from a budget of zero cells: zero marks every filled cell as overspend,
// while NoBudget marks none.
const NoBudget = -1

// Label dims the structural text so values stay at full brightness. Every label
// goes through here; inlining the escape at the assembly sites lets the rule drift.
func Label(s string) string { return Dim + s + Reset }

// GaugeColor turns a usage percentage into a warning color. The caller supplies the
// thresholds because context (40/70) and rate (80/90) warn at different points.
func GaugeColor(pct, warn, danger int) string {
	switch {
	case pct >= danger:
		return Red
	case pct >= warn:
		return Yellow
	}
	return ""
}

// Bar draws the 20-cell gauge. Cells past budget carry the overspend glyph, and
// each cell closes its own color so the following segment does not inherit it.
func Bar(pct, budget int, fill, empty, over string) string {
	if pct > 100 {
		pct = 100
	}
	if pct < 0 {
		pct = 0
	}
	filled := pct * Cells / 100
	var b strings.Builder
	for i := 0; i < Cells; i++ {
		switch {
		case i >= filled:
			b.WriteString(empty + "░" + Reset)
		case budget != NoBudget && i >= budget:
			b.WriteString(over + "▓" + Reset)
		default:
			b.WriteString(fill + "█" + Reset)
		}
	}
	return b.String()
}

// FormatReset writes the time left until target as ↺2d3h, ↺1h23m or ↺48m.
func FormatReset(target, now int64) string {
	diff := target - now
	if diff < 0 {
		diff = 0
	}
	switch {
	case diff >= 86400:
		return fmt.Sprintf("↺%dd%dh", diff/86400, (diff%86400)/3600)
	case diff >= 3600:
		return fmt.Sprintf("↺%dh%dm", diff/3600, (diff%3600)/60)
	}
	return fmt.Sprintf("↺%dm", diff/60)
}

// EffortGlyph maps a reasoning effort level to the circle glyph Claude Code shows in
// its session header plus a warm gauge color. Shape and color express the step
// together. These glyphs must not collide with the pace marker ▲ or any other render
// symbol, or the regression suite can no longer pin effort by glyph.
func EffortGlyph(level string) string {
	switch level {
	case "low":
		return Green + "○" + Reset
	case "medium":
		return Lime + "◐" + Reset
	case "high":
		return Yellow + "●" + Reset
	case "xhigh":
		return Amber214 + "◉" + Reset
	case "max":
		return Red + "◈" + Reset
	case "ultracode":
		return Magenta + "✦" + Reset
	}
	return ""
}

// FormatModel shortens a display name to "Name Version" when both are recognizable,
// and otherwise drops a leading "Claude " and everything from the first parenthesis.
func FormatModel(display string) string {
	var name, ver string
	for _, w := range strings.Split(display, " ") {
		switch w {
		case "Opus", "Sonnet", "Haiku":
			name = w
			continue
		}
		if isVersion(w) {
			ver = w
		}
	}
	if name != "" && ver != "" {
		return name + " " + ver
	}
	return trimParenthetical(strings.Replace(display, "Claude ", "", 1))
}

// isVersion matches the shell glob [0-9]*.[0-9]* narrowed to digits and dots.
func isVersion(w string) bool {
	if w == "" || w[0] < '0' || w[0] > '9' {
		return false
	}
	dot := false
	for i := 0; i < len(w); i++ {
		switch {
		case w[i] == '.':
			if i+1 < len(w) && w[i+1] >= '0' && w[i+1] <= '9' {
				dot = true
			}
		case w[i] >= '0' && w[i] <= '9':
		default:
			return false
		}
	}
	return dot
}

// trimParenthetical drops the leftmost run of spaces followed by "(" and all that
// follows, matching sed 's/ *(.*//'.
func trimParenthetical(s string) string {
	i := strings.IndexByte(s, '(')
	if i < 0 {
		return s
	}
	for i > 0 && s[i-1] == ' ' {
		i--
	}
	return s[:i]
}
