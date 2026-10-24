// Command lockholder holds the locks a ready OTLP receiver holds, until it is killed. The
// shell suites seed anchors without starting a receiver, and the statusline trusts an anchor
// only while the live lock is held by a receiver whose run the anchor carries. It writes what a
// receiver writes before it is ready: a generation file naming the run, and a heartbeat unless
// the suite made one.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/silee-tools/claude-statusline/internal/anchor"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: lockholder <state dir> <run>")
		os.Exit(2)
	}
	state, run := os.Args[1], os.Args[2]
	lock, err := anchor.LockReceiver(state)
	if err != nil {
		fmt.Fprintln(os.Stderr, "lockholder:", err)
		os.Exit(1)
	}
	defer lock.Close()
	if err := anchor.WriteGeneration(state, 1, run); err != nil {
		fmt.Fprintln(os.Stderr, "lockholder:", err)
		os.Exit(1)
	}
	if _, err := os.Stat(filepath.Join(state, "otel", "heartbeat")); err != nil {
		if err := anchor.TouchHeartbeat(state, time.Now()); err != nil {
			fmt.Fprintln(os.Stderr, "lockholder:", err)
			os.Exit(1)
		}
	}
	if err := lock.Ready(anchor.Receiver{Run: run, Addr: anchor.DefaultAddr}); err != nil {
		fmt.Fprintln(os.Stderr, "lockholder:", err)
		os.Exit(1)
	}
	fmt.Println("locked")
	for {
		time.Sleep(time.Hour)
	}
}
