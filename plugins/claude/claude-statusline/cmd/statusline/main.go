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

	"github.com/silee-tools/claude-statusline/internal/anchor"
	"github.com/silee-tools/claude-statusline/internal/gitinfo"
	"github.com/silee-tools/claude-statusline/internal/input"
	"github.com/silee-tools/claude-statusline/internal/ratelimit"
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
	home, _ := os.UserHomeDir()
	status, err := input.Parse(os.Stdin)
	if err != nil {
		fmt.Print(theme.Green + now.Format("15:04") + theme.Reset + " " +
			theme.Dim + cwdOrDot() + theme.Reset + theme.Dim + " | " + theme.Reset +
			theme.Dim + "statusline: payload unreadable" + theme.Reset)
		return
	}

	cacheDir := filepath.Join(xdg("XDG_CACHE_HOME", filepath.Join(home, ".cache")), "claude-statusline")
	configDir := resolveConfigDir(home)

	session := anchor.Input{
		StateDir: claudeStateDir(home), ConfigDir: configDir, SessionID: status.SessionID,
		Parent: os.Getppid(), Now: now,
		// Claude Code does not pass its OTEL_* settings on to the status line, so the address the
		// events go to cannot be read from there: a receiver is expected where the settings of
		// this machine send them, or where the user says.
		Addr: os.Getenv("CLAUDE_STATUSLINE_OTLP_ADDR"),
	}
	limits := windows(cacheDir, session, status)
	view := render.View{
		Clock:   now.Format("15:04"),
		Model:   theme.FormatModel(status.ModelDisplay),
		Effort:  theme.EffortGlyph(status.Effort),
		CtxPct:  status.ContextUsed() * 100 / status.WindowSize(),
		Five:    gauge(limits.Five, 18000),
		Week:    gauge(limits.Week, 604800),
		Version: status.Version,
		Session: status.SessionID,
	}
	if b := gitinfo.Branch(status.CWD, cacheDir); b != "" {
		view.Branch = shorten.Branch(b)
	}
	cols, ok := width.Terminal(cacheDir)
	view.Width = cols
	if ok && cols <= compactAtOrBelow {
		fmt.Print(render.Compact(view, now.Unix()))
		return
	}
	// The path and the account are read only for the full layout.
	view.Path = shorten.Path(status.CWD, home)
	view.Account = accountSlot(session, status)
	fmt.Print(render.Full(view, now.Unix()))
}

// windows is what the gauges draw: the payload's windows, with the ones it lacks supplied
// from what this session saw earlier in the same stretch of the same process (see
// anchor.Boundary).
func windows(cacheDir string, session anchor.Input, status input.Status) ratelimit.Pair {
	live := ratelimit.Pair{Five: sample(status.FiveHour), Week: sample(status.SevenDay)}
	return ratelimit.Resolve(cacheDir, status.SessionID, anchor.Boundary(session), live, session.Now.Unix())
}

func sample(w input.Window) ratelimit.Sample {
	return ratelimit.Sample{Present: w.Present, HasReset: w.HasReset, Pct: w.Pct, ResetsAt: w.ResetsAt}
}

func gauge(s ratelimit.Sample, window int64) render.Gauge {
	return render.Gauge{
		Present:  s.Present,
		Pct:      s.Pct,
		ResetsAt: s.ResetsAt,
		HasReset: s.HasReset,
		Window:   window,
	}
}

func xdg(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

// claudeStateDir is where the receiver's anchors and this program's per-session state live.
func claudeStateDir(home string) string {
	return filepath.Join(xdg("XDG_STATE_HOME", filepath.Join(home, ".local", "state")), "claude-statusline")
}

// fingerprintWindows are the rate-limit windows whose change inside the window casts
// doubt on the account. Both resets stay fixed while their window runs: 21 live sessions
// kept the same five-hour and seven-day resetsAt across 54 minutes of sampling.
var fingerprintWindows = []ratelimit.Window{ratelimit.WindowFive, ratelimit.WindowWeek}

// accountSlot is the Claude account of the first row: the session's anchor, marked as an
// estimate unless an in-session /login named it, with a question mark when the account
// may have changed unseen: the receiver looks stopped, the anchor is of an earlier receiver
// generation, or a rate-limit window of the session changed before it ended.
func accountSlot(in anchor.Input, status input.Status) string {
	res := anchor.Resolve(in)
	if res.Email != "" {
		live := ratelimit.Pair{Five: sample(status.FiveHour), Week: sample(status.SevenDay)}
		fingerprints := filepath.Join(in.StateDir, "fingerprints")
		if ratelimit.Fingerprint(fingerprints, status.SessionID, res.AnchorTS, fingerprintWindows, live, in.Now.Unix()) {
			res.Suspect = true
		}
	}
	return segments.Account(res.Installed, res.Email, res.Level == anchor.Estimate, res.Suspect)
}

func cwdOrDot() string {
	if d, err := os.Getwd(); err == nil {
		return d
	}
	return "."
}
