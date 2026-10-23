// Package statefile writes and prunes the small state files the statusline and the OTLP
// receiver keep under the XDG state and cache directories.
package statefile

import (
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"time"
)

// Write replaces path with data through a temporary file in the same directory, so a
// reader sees either the old content or the new one. The file is 0600 and a missing
// directory is created 0700: the files hold account emails.
func Write(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	// The temporary name carries the process id so two writers never share one, and it
	// sits beside the destination because rename cannot cross a filesystem.
	tmp := path + ".tmp." + strconv.Itoa(os.Getpid())
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

// Prune removes the regular files in dir that are older than maxAge, then the oldest of
// the rest until at most maxFiles remain (0 means no count limit). Errors are ignored:
// pruning is housekeeping and must never fail the write that triggered it.
func Prune(dir string, now time.Time, maxAge time.Duration, maxFiles int) {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	type file struct {
		path string
		mod  time.Time
	}
	var kept []file
	for _, e := range ents {
		if !e.Type().IsRegular() {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		path := filepath.Join(dir, e.Name())
		if now.Sub(info.ModTime()) > maxAge {
			os.Remove(path)
			continue
		}
		kept = append(kept, file{path, info.ModTime()})
	}
	if maxFiles <= 0 || len(kept) <= maxFiles {
		return
	}
	sort.Slice(kept, func(i, j int) bool { return kept[i].mod.Before(kept[j].mod) })
	for _, f := range kept[:len(kept)-maxFiles] {
		os.Remove(f.path)
	}
}
