// Package render assembles the compact and the full layout from a prepared view.
package render

import (
	"strconv"
	"strings"
	"time"

	"github.com/silee-tools/claude-statusline/internal/theme"
	"github.com/silee-tools/claude-statusline/internal/width"
)

// labelWidth right-aligns ctx, 5h and 7d into one column so their bars start
// at the same place.
const labelWidth = 3

const sevenDayWindow int64 = 7 * 24 * 60 * 60

// View holds everything the layouts draw. Keeping files and the environment out of
// the renderer is what lets the output format be tested without a filesystem.
type View struct {
	Clock   string   // current time, already formatted as "15:04"
	Path    string   // shortened path, already colored
	Branch  string   // shortened branch, empty when there is none
	Meta    []string // full layout: account and auth indicators; the caller dropped the empty ones
	Status  []string // compact layout: gh always, aws only when not healthy
	Model   string   // tidied model name such as "Opus 4.8"
	Effort  string   // effort glyph, empty when the model has no effort level
	CtxPct  int
	Five    Gauge
	Week    Gauge
	Version string
	Session string // full session id
	Width   int    // detected columns; the compact layout cuts its rows to it and the full layout spreads its first row across it less statusInset, 0 means neither
}

// Gauge is one rate-limit window. Window is its length in seconds — 18000 for five
// hours, 604800 for seven days — which turns the time left into a pace budget. The
// seven-day budget advances only on local Monday-to-Friday calendar days.
type Gauge struct {
	Present  bool
	Pct      int
	ResetsAt int64
	HasReset bool
	Window   int64
}

// statusInset is what Claude Code takes from the terminal's columns when statusLine.padding
// is unset: a left indent of 2 and 2 columns left empty on the right. Measured on 2.1.307
// in windows of 90 to 240 columns; a wider row is cut with an ellipsis, not wrapped.
const statusInset = 4

// Full is the layout used above 80 columns and whenever the width could not be
// determined. The first row holds the version, session id and accounts at its left end and
// the location and clock at its right end, spread across Width less statusInset. One that
// does not fit sheds the version and session id to a last row, then the accounts to a row
// of their own. A Width of 0 or less joins the groups without spreading them.
func Full(v View, now int64) string {
	place := v.Path
	if v.Branch != "" {
		place += " " + theme.Magenta + theme.BranchGlyph + v.Branch + theme.Reset
	}
	if width.Visible(place) == 0 {
		place = ""
	}
	meta := strings.Join(v.Meta, " ")

	ctx := theme.Label(ralign("ctx")) + " " +
		theme.Bar(v.CtxPct, theme.NoBudget, contextColor(v.CtxPct), "") +
		" " + contextColor(v.CtxPct) + strconv.Itoa(v.CtxPct) + "%" + theme.Reset
	ctx += modelAndEffort(v)

	foot := ""
	if v.Version != "" {
		foot = theme.Label("v" + v.Version)
	}
	if v.Session != "" {
		if foot != "" {
			foot += " "
		}
		foot += theme.Grey240 + theme.SessionGlyph + " " + v.Session + theme.Reset
	}

	five, week := fullGauge(ralign("5h"), v.Five, now), fullGauge(ralign("7d"), v.Week, now)

	right := joinGroups(place, theme.Green+v.Clock+theme.Reset)
	if row, ok := spread(v, joinGroups(foot, meta), right); ok {
		return emit(row, ctx, five, week)
	}
	if row, ok := spread(v, meta, right); ok {
		return emit(row, ctx, five, week, foot)
	}
	return emit(right, meta, ctx, five, week, foot)
}

// joinGroups puts two groups on one row, skipping an empty one so no gap is left.
func joinGroups(a, b string) string {
	if a == "" || b == "" {
		return a + b
	}
	return a + "  " + b
}

// spread puts left at the start of a row and right at its end, filling the gap so the row
// spans Width less statusInset, and reports whether both fit with at least two columns
// between them. A single group is not spread, and a Width of 0 or less joins without
// measuring. Visible counts the branch glyph as one column; a terminal that draws it as two
// spends one of the columns Claude Code leaves empty.
func spread(v View, left, right string) (string, bool) {
	row := joinGroups(left, right)
	if v.Width <= 0 {
		return row, true
	}
	limit := v.Width - statusInset
	if left == "" || right == "" {
		return row, width.Visible(row) <= limit
	}
	gap := limit - width.Visible(left) - width.Visible(right)
	if gap >= 2 {
		return left + strings.Repeat(" ", gap) + right, true
	}
	return row, false
}

// Compact is the layout for 80 columns or fewer: at most two rows, each within Width.
// Row one is the branch and the Status indicators, row two the ctx, model and rate
// values. A row with nothing to show is left out.
func Compact(v View, now int64) string {
	return emit(compactStatusRow(v), compactGaugeRow(v, now))
}

// branchGlyphCells is what the glyph is budgeted at; terminals disagree on its width,
// so the wider reading keeps the row from wrapping.
const branchGlyphCells = 2

// minBranchCells is the narrowest branch worth drawing next to the indicators.
const minBranchCells = 8

// compactStatusRow never cuts an indicator. The branch takes what they leave, with an
// ellipsis, and is dropped when less than minBranchCells remain.
func compactStatusRow(v View) string {
	status := strings.Join(v.Status, " ")
	branch := v.Branch
	if branch != "" && v.Width > 0 {
		budget := v.Width - branchGlyphCells
		if status != "" {
			budget -= 1 + width.Visible(status)
		}
		switch {
		case status != "" && budget < minBranchCells:
			branch = ""
		case budget < 1:
			budget = 1
			fallthrough
		default:
			branch = width.Fit(branch, budget)
		}
	}
	row := ""
	if branch != "" {
		row = theme.Magenta + theme.BranchGlyph + branch + theme.Reset
	}
	if status != "" {
		if row != "" {
			row += " "
		}
		row += status
	}
	return row
}

// compactGaugeRow drops the pace flame, the 7d reset, the 5h reset and the model with
// its effort, in that order, until the row fits. A width of 0 or less cuts nothing.
func compactGaugeRow(v View, now int64) string {
	row := ""
	for step := 0; step <= 4; step++ {
		row = compactGaugeRowAt(v, now, step)
		if v.Width <= 0 || width.Visible(row) <= v.Width {
			break
		}
	}
	return row
}

func compactGaugeRowAt(v View, now int64, step int) string {
	row := theme.Label("ctx") + " " + contextColor(v.CtxPct) +
		strconv.Itoa(v.CtxPct) + "%" + theme.Reset
	if step < 4 {
		row += modelAndEffort(v)
	}
	if s := compactGauge("5h", v.Five, now, step < 3, step < 1); s != "" {
		row += " " + s
	}
	if s := compactGauge("7d", v.Week, now, step < 2, step < 1); s != "" {
		row += " " + s
	}
	return row
}

func modelAndEffort(v View) string {
	out := ""
	if v.Model != "" {
		out += " " + theme.Cyan + v.Model + theme.Reset
	}
	if v.Effort != "" {
		out += " " + v.Effort
	}
	return out
}

// fullGauge draws one rate row: label, bar, percentage and the reset token. Inside the
// bar a color means one thing only — usage has run ahead of pace — so the percentage
// beside it is the sole carrier of absolute severity. Painting the bar with that
// severity too would repeat the number and, once both reached red, hide the very
// boundary the bar exists to show. A window with no overshoot hands the same grey to
// both stretches, which leaves the whole bar grey until pace is actually broken.
func fullGauge(label string, g Gauge, now int64) string {
	if !g.Present {
		return ""
	}
	color := theme.GaugeColor(g.Pct, 80, 90)
	budget, pace := paceOf(g, now)
	beyond := pace
	if beyond == "" {
		beyond = theme.Grey240
	}
	out := theme.Label(label) + " " + theme.Bar(g.Pct, budget, theme.Grey240, beyond) +
		" " + color + strconv.Itoa(g.Pct) + "%" + theme.Reset
	if g.HasReset {
		out += " " + theme.Dim + theme.FormatReset(g.ResetsAt, now) + theme.Reset
		if marker := overpaceMarker(g, now, pace); marker != "" {
			out += " " + marker
		}
	}
	return out
}

// compactGauge draws one rate value without a bar, marking pace overshoot with ▲.
// reset and fire switch the reset time and the overshoot duration on.
func compactGauge(label string, g Gauge, now int64, reset, fire bool) string {
	if !g.Present {
		return ""
	}
	color := theme.GaugeColor(g.Pct, 80, 90)
	_, pace := paceOf(g, now)
	out := theme.Label(label) + " " + color + strconv.Itoa(g.Pct) + "%" + theme.Reset
	if pace != "" {
		out += pace + "▲" + theme.Reset
	}
	if g.HasReset && reset {
		out += " " + theme.Dim + theme.FormatReset(g.ResetsAt, now) + theme.Reset
		if marker := overpaceMarker(g, now, pace); fire && marker != "" {
			out += " " + marker
		}
	}
	return out
}

// paceOf converts the time elapsed in the window into a budget of bar cells and warns
// when usage runs ahead of it. The seven-day window measures local weekday time, while
// every other window uses elapsed seconds. Both layouts share this arithmetic so the
// same input cannot produce a different warning in one of them.
func paceOf(g Gauge, now int64) (int, string) {
	elapsed, window, ok := paceTimes(g, now)
	if !ok {
		return theme.NoBudget, ""
	}
	budget := int((elapsed*theme.Cells + window/2) / window)
	if budget > theme.Cells {
		budget = theme.Cells
	}
	switch over := g.Pct*theme.Cells/100 - budget; {
	case over >= 3:
		return budget, theme.Red
	case over > 0:
		return budget, theme.Yellow
	}
	return budget, ""
}

func paceTimes(g Gauge, now int64) (int64, int64, bool) {
	if !g.HasReset || g.Window <= 0 {
		return 0, 0, false
	}
	diff := g.ResetsAt - now
	if diff < 0 {
		diff = 0
	}
	elapsed, window := g.Window-diff, g.Window
	if g.Window == sevenDayWindow {
		start, end := g.ResetsAt-g.Window, g.ResetsAt
		if now < start {
			now = start
		}
		if now > end {
			now = end
		}
		elapsed = businessSecondsBetween(start, now)
		window = businessSecondsBetween(start, end)
	}
	if elapsed < 0 {
		elapsed = 0
	}
	if window <= 0 {
		return 0, 0, false
	}
	return elapsed, window, true
}

func overpaceMarker(g Gauge, now int64, pace string) string {
	if pace == "" {
		return ""
	}
	elapsed, window, ok := paceTimes(g, now)
	if !ok {
		return ""
	}
	over := int64(g.Pct)*window/100 - elapsed
	if over <= 0 {
		return ""
	}
	return "(🔥" + theme.FormatDuration(over) + ")"
}

func businessSecondsBetween(start, end int64) int64 {
	if end <= start {
		return 0
	}
	from := time.Unix(start, 0).In(time.Local)
	to := time.Unix(end, 0).In(time.Local)
	day := time.Date(from.Year(), from.Month(), from.Day(), 0, 0, 0, 0, time.Local)
	var seconds int64
	for day.Before(to) {
		next := day.AddDate(0, 0, 1)
		if day.Weekday() != time.Saturday && day.Weekday() != time.Sunday {
			segmentStart, segmentEnd := from, to
			if segmentStart.Before(day) {
				segmentStart = day
			}
			if segmentEnd.After(next) {
				segmentEnd = next
			}
			if segmentEnd.After(segmentStart) {
				seconds += int64(segmentEnd.Sub(segmentStart) / time.Second)
			}
		}
		day = next
	}
	return seconds
}

func contextColor(pct int) string { return theme.GaugeColor(pct, 40, 70) }

func ralign(s string) string {
	if n := labelWidth - len(s); n > 0 {
		return strings.Repeat(" ", n) + s
	}
	return s
}

// emit joins the non-empty rows with newlines and adds none at the end.
func emit(rows ...string) string {
	kept := make([]string, 0, len(rows))
	for _, r := range rows {
		if r != "" {
			kept = append(kept, r)
		}
	}
	return strings.Join(kept, "\n")
}
