package statefile

import (
	"errors"
	"io"
	"os"
	"syscall"
)

// ErrNotRegular is a state file's path holding something that is not a regular file: a FIFO,
// a device, a directory or a link.
var ErrNotRegular = errors.New("statefile: not a regular file")

// Read reads a state file. Write puts a regular file there, so anything else is not state:
// it opens without blocking, so a FIFO left in the file's place cannot hold the reader, does
// not follow a link, and reads only a regular file (anything else is ErrNotRegular).
func Read(path string) ([]byte, error) {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK|syscall.O_NOFOLLOW, 0)
	if err != nil {
		if errors.Is(err, syscall.ELOOP) { // what O_NOFOLLOW answers for a link
			return nil, ErrNotRegular
		}
		return nil, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !fi.Mode().IsRegular() {
		return nil, ErrNotRegular
	}
	return io.ReadAll(f)
}
