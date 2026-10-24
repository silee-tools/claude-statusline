// Command lockholder holds the locks a ready OTLP receiver holds, until it is killed. The
// shell suites seed anchors without starting a receiver, and the statusline trusts an anchor
// only while the live lock is held.
package main

import (
	"fmt"
	"os"
	"time"

	"github.com/silee-tools/claude-statusline/internal/anchor"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: lockholder <state dir>")
		os.Exit(2)
	}
	lock, err := anchor.LockReceiver(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, "lockholder:", err)
		os.Exit(1)
	}
	defer lock.Close()
	if err := lock.Ready(); err != nil {
		fmt.Fprintln(os.Stderr, "lockholder:", err)
		os.Exit(1)
	}
	fmt.Println("locked")
	for {
		time.Sleep(time.Hour)
	}
}
