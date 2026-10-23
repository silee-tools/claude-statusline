package ratelimit

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/silee-tools/claude-statusline/internal/statefile"
)

// Window names one of the two rate-limit windows.
type Window int

const (
	WindowFive Window = iota
	WindowWeek
)

const (
	// fingerprintHold is how long a window may differ from its baseline before it counts.
	fingerprintHold = 60 // seconds
	// fingerprintMaxAge is how long a session's baseline file is kept after its last write.
	fingerprintMaxAge   = 30 * 24 * time.Hour
	fingerprintMaxFiles = 2000
)

type baseline struct {
	reset int64 // the resetsAt the window had when the baseline was taken
	since int64 // when the payload first showed a different value, 0 while it matches
}

type fingerprintState struct {
	anchor int64
	win    [2]baseline
}

func (w Window) sample(p Pair) Sample {
	if w == WindowFive {
		return p.Five
	}
	return p.Week
}

var windowKeys = [2][2]string{{"five", "fiveSince"}, {"week", "weekSince"}}

func loadFingerprint(file string) fingerprintState {
	var st fingerprintState
	b, err := os.ReadFile(file)
	if err != nil {
		return st
	}
	for _, line := range strings.Split(string(b), "\n") {
		k, v, found := strings.Cut(line, "=")
		if !found {
			continue
		}
		n, _ := strconv.ParseInt(v, 10, 64)
		switch k {
		case "anchor":
			st.anchor = n
		case "five":
			st.win[WindowFive].reset = n
		case "fiveSince":
			st.win[WindowFive].since = n
		case "week":
			st.win[WindowWeek].reset = n
		case "weekSince":
			st.win[WindowWeek].since = n
		}
	}
	return st
}

func (st fingerprintState) encode() []byte {
	var b strings.Builder
	b.WriteString("anchor=" + strconv.FormatInt(st.anchor, 10) + "\n")
	for w, keys := range windowKeys {
		if st.win[w].reset != 0 {
			b.WriteString(keys[0] + "=" + strconv.FormatInt(st.win[w].reset, 10) + "\n")
			b.WriteString(keys[1] + "=" + strconv.FormatInt(st.win[w].since, 10) + "\n")
		}
	}
	return []byte(b.String())
}

// Fingerprint says whether a window of the session changed before it ended, which a
// session on one account does not do: the reset time of a window is fixed by the account.
// A change inside the window means the session now runs on another account's credentials,
// which no event announces. It is a doubt, never a correction: nothing here names the
// account.
//
// The session's baseline (dir/<sessionID>.env) is the reset time of each listed window
// as it was when the anchor with time anchorTS was first seen; a new anchor takes a new
// baseline, because a /login changes the account on purpose. A window whose payload
// value differs from the baseline for longer than a minute, while the baseline window has
// not ended, is the doubt. Once the baseline window has ended a new value is the next
// window and becomes the baseline. windows is which windows count.
func Fingerprint(dir, sessionID string, anchorTS int64, windows []Window, live Pair, now int64) bool {
	if !validID(sessionID) {
		return false
	}
	file := filepath.Join(dir, sessionID+".env")
	st := loadFingerprint(file)
	before := st
	if st.anchor != anchorTS {
		st = fingerprintState{anchor: anchorTS}
	}
	doubt := false
	for _, w := range windows {
		s := w.sample(live)
		if !s.Complete() {
			continue
		}
		b := &st.win[w]
		switch {
		case b.reset == 0, now >= b.reset:
			*b = baseline{reset: s.ResetsAt}
		case s.ResetsAt == b.reset:
			b.since = 0
		case b.since == 0:
			b.since = now
		case now-b.since > fingerprintHold:
			doubt = true
		}
	}
	if st != before {
		if statefile.Write(file, st.encode()) == nil {
			statefile.Prune(dir, time.Unix(now, 0), fingerprintMaxAge, fingerprintMaxFiles)
		}
	}
	return doubt
}
