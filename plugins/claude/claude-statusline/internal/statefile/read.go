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

// maxRead bounds what Read and ReadFollow return: what they read is a few lines of state,
// cache or config, so a regular file past this is cut there rather than held in memory.
const maxRead = 1 << 20

// Read reads a state file. Write puts a regular file there, so anything else is not state:
// it opens without blocking, so a FIFO left in the file's place cannot hold the reader, does
// not follow a link, and reads only a regular file (anything else is ErrNotRegular).
func Read(path string) ([]byte, error) { return read(path, syscall.O_NOFOLLOW) }

// ReadFollow is Read for a file that another program or the user writes or places, such as
// a config a dotfile manager links in: it follows links. What the path ends on must still
// be a regular file, opened without blocking, so a link to a FIFO is ErrNotRegular too.
func ReadFollow(path string) ([]byte, error) { return read(path, 0) }

func read(path string, flags int) ([]byte, error) {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK|flags, 0)
	if err != nil {
		if errors.Is(err, syscall.ELOOP) { // O_NOFOLLOW's answer for a link, or a loop of links
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
	return io.ReadAll(io.LimitReader(f, maxRead))
}
