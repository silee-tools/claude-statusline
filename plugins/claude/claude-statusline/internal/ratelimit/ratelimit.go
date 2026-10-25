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
// received one yet. It is also the boundary's own: the same conversation resumed by
// another process, or after a /login, may run on another account, so a file written under
// a different boundary supplies nothing and is replaced.
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

// How long a session's file is kept after its last write, and how many the directory keeps.
const (
	cacheMaxAge   = 2 * 24 * time.Hour
	cacheMaxFiles = 2000
)

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
	p, _ := load(file)
	return p
}

// load also returns the boundary the file was written under, "" when it names none.
func load(file string) (Pair, string) {
	var p Pair
	b, err := statefile.Read(file)
	if err != nil {
		return p, ""
	}
	var boundary, fivePct, fiveReset, weekPct, weekReset string
	for _, line := range strings.Split(string(b), "\n") {
		k, v, found := strings.Cut(line, "=")
		if !found {
			continue
		}
		switch k {
		case "boundary":
			boundary = v
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
	return Pair{Five: parse(fivePct, fiveReset), Week: parse(weekPct, weekReset)}, boundary
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
func Store(file string, p Pair) error { return store(file, "", p) }

func store(file, boundary string, p Pair) error {
	var b strings.Builder
	if boundary != "" {
		fmt.Fprintf(&b, "boundary=%s\n", boundary)
	}
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
// more than two days and the oldest beyond 2,000. A session id that is not a plain
// identifier, or an empty boundary, gets no file: what the payload carries is drawn and
// nothing is remembered.
//
// The boundary says in which stretch of the session the windows were seen (see
// anchor.Boundary). A file written under another boundary is dropped, so a conversation
// that a new process resumes, or that logged in again, never draws the windows of the
// account it ran on before, not even to fill the one window its payload still lacks.
func Resolve(cacheDir, sessionID, boundary string, live Pair, now int64) Pair {
	if !validID(sessionID) || boundary == "" {
		show5, _ := resolveWindow(live.Five, Sample{}, now)
		show7, _ := resolveWindow(live.Week, Sample{}, now)
		return Pair{Five: show5, Week: show7}
	}
	dir := filepath.Join(cacheDir, "rate-limits")
	file := filepath.Join(dir, sessionID+".env")
	cached, stored := load(file)
	if stored != boundary {
		cached = Pair{}
	}
	showFive, keepFive := resolveWindow(live.Five, cached.Five, now)
	showWeek, keepWeek := resolveWindow(live.Week, cached.Week, now)
	merged := Pair{Five: keepFive, Week: keepWeek}
	if merged != cached || (stored != "" && stored != boundary) {
		switch {
		case merged == (Pair{}):
			os.Remove(file)
		case store(file, boundary, merged) == nil:
			statefile.Prune(dir, time.Unix(now, 0), cacheMaxAge, cacheMaxFiles)
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
