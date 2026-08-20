package width

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"unsafe"
)

// ancestorDepth is how far up the process chain the tty search goes. A wrapper can
// sit between this process and the terminal, so looking only at the parent is not
// enough, and an unbounded walk would spend a `ps` per level on a chain that has no
// terminal at all.
const ancestorDepth = 4

type winsize struct {
	rows, cols, xpixel, ypixel uint16
}

// Terminal reports the terminal column count. It returns ok=false when the width
// cannot be determined; filling in a default would leave the caller unable to tell
// "undetermined" from "that many columns", which is what selects the full layout.
func Terminal(cacheDir string) (int, bool) {
	if v := os.Getenv("CLAUDE_STATUSLINE_WIDTH"); v != "" && isDigits(v) {
		n, err := strconv.Atoi(v)
		if err == nil {
			return n, true
		}
	}
	path, ok := ttyPath(cacheDir)
	if !ok {
		return 0, false
	}
	cols, err := deviceCols(path)
	if err != nil {
		// The device is gone. Drop the cached path so the next render probes again
		// instead of reusing a dead entry forever.
		if cacheDir != "" {
			os.Remove(filepath.Join(cacheDir, "tty-path.env"))
		}
		return 0, false
	}
	return cols, true
}

// deviceCols asks the device for its current window size. Reading it on every render
// is what makes a terminal resize show up; only the path is cached.
func deviceCols(path string) (int, error) {
	f, err := os.OpenFile(path, os.O_RDONLY, 0)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	var ws winsize
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(),
		uintptr(syscall.TIOCGWINSZ), uintptr(unsafe.Pointer(&ws))); errno != 0 {
		return 0, errno
	}
	return int(ws.cols), nil
}

// ttyPath finds the device the terminal is attached to, caching it under the parent
// pid. That pid is stable for the session, so the cache holds without revalidation
// and the `ps` calls happen once rather than once per render.
func ttyPath(cacheDir string) (string, bool) {
	ppid := os.Getppid()
	cache := ""
	if cacheDir != "" {
		cache = filepath.Join(cacheDir, "tty-path.env")
	}

	if cache != "" {
		if p, ok := cachedPath(cache, ppid); ok {
			return p, true
		}
	}

	dir := os.Getenv("CLAUDE_STATUSLINE_TTY_DIR")
	if dir == "" {
		dir = "/dev"
	}
	found := ""
	for pid, depth := ppid, 0; depth < ancestorDepth; depth++ {
		out, err := exec.Command("ps", "-o", "tty=,ppid=", "-p", strconv.Itoa(pid)).Output()
		if err != nil {
			break
		}
		fields := strings.Fields(string(out))
		if len(fields) == 0 {
			break
		}
		if fields[0] != "" && fields[0] != "??" {
			found = filepath.Join(dir, fields[0])
			break
		}
		if len(fields) < 2 {
			break
		}
		parent, err := strconv.Atoi(fields[1])
		if err != nil {
			break
		}
		pid = parent
	}
	if found == "" {
		return "", false
	}

	if cache != "" && os.MkdirAll(cacheDir, 0o755) == nil {
		_ = os.WriteFile(cache,
			[]byte("ppid="+strconv.Itoa(ppid)+"\npath="+found+"\n"), 0o600)
	}
	return found, true
}

func cachedPath(cache string, ppid int) (string, bool) {
	b, err := os.ReadFile(cache)
	if err != nil {
		return "", false
	}
	var gotPPID, path string
	for _, line := range strings.Split(string(b), "\n") {
		k, v, found := strings.Cut(line, "=")
		if !found {
			continue
		}
		switch k {
		case "ppid":
			gotPPID = v
		case "path":
			path = v
		}
	}
	if gotPPID != strconv.Itoa(ppid) || path == "" {
		return "", false
	}
	return path, true
}

func isDigits(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}
