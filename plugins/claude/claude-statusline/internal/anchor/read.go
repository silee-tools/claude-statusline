package anchor

import (
	"errors"
	"io"
	"os"
	"syscall"
)

// errNotRegular is a state file's path holding something that is not a regular file.
var errNotRegular = errors.New("anchor: not a regular file")

// readRegular reads a state file. It opens without blocking, so a FIFO left in the file's
// place cannot hold the statusline, follows links as os.ReadFile does, and reads only a
// regular file: a FIFO, a device or a directory is errNotRegular.
func readRegular(path string) ([]byte, error) {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !fi.Mode().IsRegular() {
		return nil, errNotRegular
	}
	return io.ReadAll(f)
}
