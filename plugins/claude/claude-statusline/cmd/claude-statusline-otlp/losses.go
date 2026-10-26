package main

import (
	"fmt"
	"strings"
	"time"
)

// otel/losses says why the receiver counted each of its last lossLines losses; a supervised
// receiver's stderr is /dev/null. The receiver replaces the whole file at each loss and removes
// it at start, so it holds one run's last 20 lines (about 2 KB) with no rotation or other
// cleanup. A line has fixed fields only, never anything a request carried.
const lossLines = 20

// lossRecord is the lines of otel/losses; the receiver's mu guards it.
type lossRecord struct{ lines []string }

// add records a loss counted at now, which moved the receiver to generation gen, and returns the
// new content of the file.
func (l *lossRecord) add(now time.Time, gen int64, kind, cause string, bytes int64) []byte {
	l.lines = append(l.lines, fmt.Sprintf("ts=%d gen=%d kind=%s cause=%s bytes=%d", now.UnixMilli(), gen, kind, cause, bytes))
	if len(l.lines) > lossLines {
		l.lines = l.lines[1:]
	}
	return []byte(strings.Join(l.lines, "\n") + "\n")
}
