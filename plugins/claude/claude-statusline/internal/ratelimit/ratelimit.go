// Package ratelimit shares the five-hour and seven-day usage windows between sessions
// through one file in the cache directory.
//
// The payload wins over the file whenever it carries a window. It is the only value that
// describes the account as it is right now, and a stored sample says nothing about how
// old it is: a five-hour window rolls, so its reset moves backward when the current one
// started earlier than the stored one, and a percentage drops when the account state
// does. Ranking two samples by those numbers therefore lets a stale one outlive the live
// one, which froze the display at a value hours old. The file only supplies a window the
// payload left out, which is a render before any response header has reached the session.
package ratelimit

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Sample is one observation of one window. Present says a percentage arrived; HasReset
// says the reset time arrived with it, without which the sample cannot be aged out.
type Sample struct {
	Present  bool
	HasReset bool
	Pct      int
	ResetsAt int64
}

// Pair is both windows.
type Pair struct{ Five, Week Sample }

// Complete reports whether the sample can be judged for expiry.
func (s Sample) Complete() bool { return s.Present && s.HasReset }

const fileName = "rate-limits.env"

// Load reads <cacheDir>/rate-limits.env. A missing or unreadable file yields two absent
// samples, and a damaged window drops on its own without taking the other one with it.
func Load(cacheDir string) Pair {
	var p Pair
	b, err := os.ReadFile(filepath.Join(cacheDir, fileName))
	if err != nil {
		return p
	}
	var fivePct, fiveReset, weekPct, weekReset string
	for _, line := range strings.Split(string(b), "\n") {
		k, v, found := strings.Cut(line, "=")
		if !found {
			continue
		}
		switch k {
		case "fivePct":
			fivePct = v
		case "fiveReset":
			fiveReset = v
		case "weekPct":
			weekPct = v
		case "weekReset":
			weekReset = v
		}
	}
	return Pair{Five: parse(fivePct, fiveReset), Week: parse(weekPct, weekReset)}
}

// parse takes a window only when both numbers read. Store never writes a window without
// its reset time, so one that lacks it is damage, and a percentage that cannot be aged
// out would otherwise outlive its window forever.
func parse(pct, reset string) Sample {
	n, err := strconv.Atoi(pct)
	if err != nil {
		return Sample{}
	}
	r, err := strconv.ParseInt(reset, 10, 64)
	if err != nil {
		return Sample{}
	}
	return Sample{Present: true, HasReset: true, Pct: n, ResetsAt: r}
}

// Store replaces the file with p, keeping only the windows that carry a reset time.
func Store(cacheDir string, p Pair) error {
	if err := os.MkdirAll(cacheDir, 0o755); err != nil {
		return err
	}
	var b strings.Builder
	if p.Five.Complete() {
		fmt.Fprintf(&b, "fivePct=%d\nfiveReset=%d\n", p.Five.Pct, p.Five.ResetsAt)
	}
	if p.Week.Complete() {
		fmt.Fprintf(&b, "weekPct=%d\nweekReset=%d\n", p.Week.Pct, p.Week.ResetsAt)
	}
	final := filepath.Join(cacheDir, fileName)
	// The temporary name carries the process id so two renderers never write the same
	// one, and it sits in the destination directory because rename cannot cross a
	// filesystem.
	tmp := final + ".tmp." + strconv.Itoa(os.Getpid())
	if err := os.WriteFile(tmp, []byte(b.String()), 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, final); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

// Resolve returns what to draw for both windows and leaves what this session observed
// behind for the next session to read. It writes only when that differs from what the
// file already holds, so a render that observes nothing new costs one read.
func Resolve(cacheDir string, live Pair, now int64) Pair {
	cached := Load(cacheDir)
	showFive, keepFive := resolveWindow(live.Five, cached.Five, now)
	showWeek, keepWeek := resolveWindow(live.Week, cached.Week, now)
	if merged := (Pair{Five: keepFive, Week: keepWeek}); merged != cached {
		_ = Store(cacheDir, merged)
	}
	return Pair{Five: showFive, Week: showWeek}
}

func resolveWindow(live, cached Sample, now int64) (show, keep Sample) {
	if live.Present {
		if !live.Complete() {
			// A percentage without its reset renders, but storing it would leave behind a
			// value nothing can age out.
			return live, cached
		}
		return live, live
	}
	// Only a value the session did not observe itself is dropped for having expired.
	if cached.Complete() && cached.ResetsAt <= now {
		return Sample{}, cached
	}
	return cached, cached
}
