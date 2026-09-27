//go:build !darwin

package segments

import "time"

// birthTime has no portable creation-time syscall outside darwin, so every
// caller sees "unreadable" there and AWS renders aws:?.
func birthTime(path string) (time.Time, bool) {
	return time.Time{}, false
}
