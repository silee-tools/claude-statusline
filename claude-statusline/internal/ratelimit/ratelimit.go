// Package ratelimit shares the five-hour and seven-day usage windows between sessions
// through one file in the cache directory.
//
// Which of two observations is newer is decided by the values themselves, not by when
// they were read: a later reset wins, and within one window the higher percentage wins.
// Every writer stores the winner of what it read and what it holds, so concurrent
// writers converge and the file never moves backward.
package ratelimit

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
