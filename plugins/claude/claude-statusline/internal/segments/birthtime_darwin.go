package segments

import (
	"os"
	"syscall"
	"time"
)

// birthTime reads a file's creation time via the darwin-only Birthtimespec field.
func birthTime(path string) (time.Time, bool) {
	info, err := os.Stat(path)
	if err != nil {
		return time.Time{}, false
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return time.Time{}, false
	}
	return time.Unix(st.Birthtimespec.Sec, st.Birthtimespec.Nsec), true
}
