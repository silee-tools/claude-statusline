// Command statusline renders the Claude Code status line in one process.
//
// The payload arrives on stdin as JSON and the rendered rows go to stdout without a
// trailing newline. Nothing here exits non-zero: a status line that prints an error
// instead of a line is worse than one that prints less, so every failure degrades to
// the widest row that still holds.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/silee-tools/claude-statusline/internal/costcache"
	"github.com/silee-tools/claude-statusline/internal/gitinfo"
	"github.com/silee-tools/claude-statusline/internal/input"
	"github.com/silee-tools/claude-statusline/internal/render"
	"github.com/silee-tools/claude-statusline/internal/segments"
	"github.com/silee-tools/claude-statusline/internal/shorten"
	"github.com/silee-tools/claude-statusline/internal/theme"
	"github.com/silee-tools/claude-statusline/internal/width"
)

// compactAtOrBelow is the width at which the layout switches. An undetermined width
// takes the full layout so nothing is dropped when the available space is unknown.
const compactAtOrBelow = 80

func main() {
	// One clock reading feeds every formatter. Reading the time per segment lets a
	// second boundary fall between two of them, which moves a pace budget by a cell
	// between the bar and the percentage beside it.
	now := time.Now()

	status, err := input.Parse(os.Stdin)
	if err != nil {
		fmt.Print(theme.Green + now.Format("15:04") + theme.Reset + " " +
			theme.Dim + cwdOrDot() + theme.Reset + theme.Dim + " | " + theme.Reset +
			theme.Dim + "statusline: payload unreadable" + theme.Reset)
		return
	}

	home, _ := os.UserHomeDir()
	cacheDir := filepath.Join(xdg("XDG_CACHE_HOME", filepath.Join(home, ".cache")), "claude-statusline")
	dataDir := xdg("XDG_DATA_HOME", filepath.Join(home, ".local", "share"))
	configDir := xdg("XDG_CONFIG_HOME", filepath.Join(home, ".config"))
	claudeConfigDir := os.Getenv("CLAUDE_CONFIG_DIR")
	if claudeConfigDir == "" {
		claudeConfigDir = home
	}
	credsFile := os.Getenv("AWS_SHARED_CREDENTIALS_FILE")
	if credsFile == "" {
		credsFile = filepath.Join(home, ".aws", "credentials")
	}

	view := render.View{
		Clock:   now.Format("15:04"),
		Path:    shorten.Path(status.CWD, home),
		Model:   theme.FormatModel(status.ModelDisplay),
		Effort:  theme.EffortGlyph(status.Effort),
		CtxPct:  status.ContextUsed() * 100 / status.WindowSize(),
		Five:    gauge(status.FiveHour, 18000),
		Week:    gauge(status.SevenDay, 604800),
		Version: status.Version,
		Session: status.SessionID,
	}
	if b := gitinfo.Branch(status.CWD, cacheDir); b != "" {
		view.Branch = shorten.Branch(b)
	}
	for _, s := range []string{
		segments.ClaudeAccount(claudeConfigDir, cacheDir),
		segments.GitHubAccount(dataDir, configDir, now.Unix()),
		segments.AWS(credsFile, dataDir, cacheDir, now.Unix()),
	} {
		if s != "" {
			view.Meta = append(view.Meta, s)
		}
	}

	cols, ok := width.Terminal(cacheDir)
	if ok && cols <= compactAtOrBelow {
		view.Width = cols
		fmt.Print(render.Compact(view, now.Unix()))
		return
	}
	view.Width = cols
	view.Cost = costLine(cacheDir, now)
	fmt.Print(render.Full(view, now.Unix()))
}

func gauge(w input.Window, window int64) render.Gauge {
	return render.Gauge{
		Present:  w.Present,
		Pct:      w.Pct,
		ResetsAt: w.ResetsAt,
		HasReset: w.HasReset,
		Window:   window,
	}
}

// costLine is read only for the full layout, which is the only one that shows it.
func costLine(cacheDir string, now time.Time) render.CostLine {
	c := costcache.Load(cacheDir)
	line := render.CostLine{
		Available: c.Available,
		Weekly:    c.Weekly,
		Monthly:   c.Monthly,
		MonthDays: costcache.MonthDays(now),
	}
	for _, seg := range c.DailySegments() {
		line.Daily = append(line.Daily, theme.Label(seg.Label)+" $"+seg.Amount)
	}
	return line
}

func xdg(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

func cwdOrDot() string {
	if d, err := os.Getwd(); err == nil {
		return d
	}
	return "."
}
