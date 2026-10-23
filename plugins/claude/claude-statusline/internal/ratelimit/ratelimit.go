// Package ratelimit keeps the five-hour and seven-day usage windows a session last saw,
// in one file per session in the cache directory, and watches those windows for a sign
// that the session's account changed.
//
// The payload wins over the file whenever it carries a window. It is the only value that
// describes the account as it is right now, and a stored sample says nothing about how
// old it is: a five-hour window rolls, so its reset moves backward when the current one
// started earlier than the stored one, and a percentage drops when the account state
// does. Ranking two samples by those numbers therefore lets a stale one outlive the live
// one, which froze the display at a value hours old. The file only supplies a window the
// payload left out, which is a render before any response header has reached the session.
//
// The file is the session's own. A file shared by every session of a config directory
// drew another session's window, and so another account's, on a session that had not
// received one yet.
package ratelimit

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/silee-tools/claude-statusline/internal/statefile"
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

// cacheMaxAge is how long a session's file is kept after its last write.
const cacheMaxAge = 2 * 24 * time.Hour

// validID accepts the characters a session id can carry and nothing that could leave the
// directory.
func validID(id string) bool {
	if id == "" || len(id) > 64 {
		return false
	}
	for i := 0; i < len(id); i++ {
		c := id[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

// Load reads one session file. A missing or unreadable file yields two absent samples, and
// a damaged window drops on its own without taking the other one with it.
func Load(file string) Pair {
	var p Pair
	b, err := os.ReadFile(file)
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
func Store(file string, p Pair) error {
	var b strings.Builder
	if p.Five.Complete() {
		fmt.Fprintf(&b, "fivePct=%d\nfiveReset=%d\n", p.Five.Pct, p.Five.ResetsAt)
	}
	if p.Week.Complete() {
		fmt.Fprintf(&b, "weekPct=%d\nweekReset=%d\n", p.Week.Pct, p.Week.ResetsAt)
	}
	return statefile.Write(file, []byte(b.String()))
}

// Resolve returns what to draw for both windows and leaves what this session observed
// behind for its next render to read, in <cacheDir>/rate-limits/<sessionID>.env. It writes
// only when that differs from what the file already holds, so a render that observes
// nothing new costs one read, and a write also removes the files of sessions idle for
// more than two days. A session id that is not a plain identifier gets no file: what the
// payload carries is drawn and nothing is remembered.
func Resolve(cacheDir, sessionID string, live Pair, now int64) Pair {
	if !validID(sessionID) {
		show5, _ := resolveWindow(live.Five, Sample{}, now)
		show7, _ := resolveWindow(live.Week, Sample{}, now)
		return Pair{Five: show5, Week: show7}
	}
	dir := filepath.Join(cacheDir, "rate-limits")
	file := filepath.Join(dir, sessionID+".env")
	cached := Load(file)
	showFive, keepFive := resolveWindow(live.Five, cached.Five, now)
	showWeek, keepWeek := resolveWindow(live.Week, cached.Week, now)
	if merged := (Pair{Five: keepFive, Week: keepWeek}); merged != cached {
		if Store(file, merged) == nil {
			statefile.Prune(dir, time.Unix(now, 0), cacheMaxAge, 0)
		}
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
