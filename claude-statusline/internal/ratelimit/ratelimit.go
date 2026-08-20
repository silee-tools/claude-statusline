// Package ratelimit shares the five-hour and seven-day usage windows between sessions
// through one file in the cache directory.
//
// Which of two observations is newer is decided by the values themselves, not by when
// they were read: a later reset wins, and within one window the higher percentage wins.
// Every writer stores the winner of what it read and what it holds, so concurrent
// writers converge and the file never moves backward.
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

// Newer returns the sample describing the more recent state of a fixed window. A later
// reset wins; on a tie the higher percentage wins. An incomplete sample always loses.
func Newer(a, b Sample) Sample {
	switch {
	case !a.Complete():
		return b
	case !b.Complete():
		return a
	case a.ResetsAt != b.ResetsAt:
		if a.ResetsAt > b.ResetsAt {
			return a
		}
		return b
	case a.Pct >= b.Pct:
		return a
	default:
		return b
	}
}

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
