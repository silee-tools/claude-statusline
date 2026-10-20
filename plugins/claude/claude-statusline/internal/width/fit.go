// Package width measures display width, fits text into a column budget,
// and detects the terminal width.
package width

import "strings"

// wideRanges are the ranges that occupy two columns: Hangul jamo, CJK, Hangul
// syllables, CJK compatibility, vertical forms and the two fullwidth blocks.
// Everything at U+10000 and above counts as two as well, which is where the emoji
// planes live. Widening or narrowing this table moves where existing rows get cut,
// so a range is added only with a display-width reason, never for tidiness.
var wideRanges = [...][2]rune{
	{0x1100, 0x115F},
	{0x2E80, 0xA4CF},
	{0xAC00, 0xD7A3},
	{0xF900, 0xFAFF},
	{0xFE30, 0xFE6F},
	{0xFF00, 0xFF60},
	{0xFFE0, 0xFFE6},
}

func isWide(r rune) bool {
	if r >= 0x10000 {
		return true
	}
	for _, rg := range wideRanges {
		if r >= rg[0] && r <= rg[1] {
			return true
		}
	}
	return false
}

// Visible is the display width of s. An ANSI escape (ESC through the first "m")
// counts as zero.
func Visible(s string) int {
	total := 0
	for _, r := range escapeSkipper(s) {
		if isWide(r) {
			total += 2
		} else {
			total++
		}
	}
	return total
}

// escapeSkipper returns the runes of s with ANSI escapes removed.
func escapeSkipper(s string) []rune {
	out := make([]rune, 0, len(s))
	rs := []rune(s)
	for i := 0; i < len(rs); i++ {
		if rs[i] == 0x1b {
			for i++; i < len(rs); i++ {
				if rs[i] == 'm' {
					break
				}
			}
			continue
		}
		out = append(out, rs[i])
	}
	return out
}

// cut keeps the leading runes of s that fit in limit columns. Escapes are carried
// over without spending budget, and a wide rune that only half fits is left out.
func cut(s string, limit int) string {
	var b strings.Builder
	total := 0
	rs := []rune(s)
	for i := 0; i < len(rs); i++ {
		if rs[i] == 0x1b {
			b.WriteRune(rs[i])
			for i++; i < len(rs); i++ {
				b.WriteRune(rs[i])
				if rs[i] == 'm' {
					break
				}
			}
			continue
		}
		w := 1
		if isWide(rs[i]) {
			w = 2
		}
		if total+w > limit {
			break
		}
		total += w
		b.WriteRune(rs[i])
	}
	return b.String()
}

// Fit cuts s only when it overflows, spending one column on the ellipsis. A cut
// can end inside an open color, so a colored input is closed with a reset.
func Fit(s string, limit int) string {
	if Visible(s) <= limit {
		return s
	}
	out := cut(s, limit-1) + "…"
	if strings.ContainsRune(s, 0x1b) {
		out += "\033[0m"
	}
	return out
}
