// Command claude-statusline-otlp receives Claude Code's OpenTelemetry log events on a
// loopback port and keeps, per session, the account the statusline shows.
//
// It stores no event: for each session id it writes the latest anchor (see internal/anchor)
// and a heartbeat the statusline reads to tell whether anyone is listening. stderr carries
// only what happened (start, stop, failure kinds), never a value from a request.
//
// Anything it could not store makes it answer 503 so the exporter retries, bumps the
// generation (otel/generation) so the anchors it holds are doubted, and stops touching the
// heartbeat until a write succeeds again. The same bump marks every start, because a
// /login that arrived while it was down is lost. Once an hour it removes what is past
// retention.
//
// Exit codes: 0 after SIGINT or SIGTERM; 75 when the executable at its own path was
// replaced, so a supervisor that restarts on failure brings up the new build; 1 when the
// address is not a loopback address, the port cannot be bound, or the state directory
// cannot be prepared.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/silee-tools/claude-statusline/internal/anchor"
)

const (
	exitFailed   = 1
	exitReplaced = 75
)

type config struct {
	Addr       string
	StateDir   string
	ExePath    string // the file whose replacement stops the receiver; "" disables the check
	WatchEvery time.Duration
	BeatEvery  time.Duration
	SweepEvery time.Duration // how often to remove state past retention; 0 means hourly
	OnListen   func(net.Addr)
}

func main() {
	addr := flag.String("addr", "127.0.0.1:14318", "loopback address to listen on (an IP literal)")
	watch := flag.Duration("watch", 30*time.Second, "how often to check whether the executable was replaced")
	beat := flag.Duration("beat", 30*time.Second, "how often to touch the heartbeat file")
	flag.Parse()

	home, _ := os.UserHomeDir()
	state := os.Getenv("XDG_STATE_HOME")
	if state == "" {
		state = filepath.Join(home, ".local", "state")
	}
	exe, _ := os.Executable()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	os.Exit(serve(ctx, config{
		Addr: *addr, StateDir: filepath.Join(state, "claude-statusline"), ExePath: exe,
		WatchEvery: *watch, BeatEvery: *beat,
	}, os.Stderr))
}

func serve(ctx context.Context, cfg config, stderr io.Writer) int {
	say := func(msg string) { fmt.Fprintln(stderr, "claude-statusline-otlp:", msg) }

	if !loopback(cfg.Addr) {
		say("refused: the address is not a loopback address")
		return exitFailed
	}
	ln, err := net.Listen("tcp", cfg.Addr)
	if err != nil {
		say("bind failed")
		return exitFailed
	}
	defer ln.Close()
	if err := os.MkdirAll(filepath.Join(cfg.StateDir, "otel", "sessions"), 0o700); err != nil {
		say("state directory unavailable")
		return exitFailed
	}
	// Events sent while no receiver ran are gone, so every anchor stored before this
	// start is doubted until a later event replaces it.
	if err := anchor.WriteGeneration(cfg.StateDir, time.Now()); err != nil {
		say("generation unavailable")
		return exitFailed
	}
	if err := anchor.TouchHeartbeat(cfg.StateDir, time.Now()); err != nil {
		say("heartbeat unavailable")
		return exitFailed
	}
	anchor.Sweep(cfg.StateDir, time.Now())

	// Apply reads the stored anchor before replacing it, so concurrent requests take turns.
	var mu sync.Mutex
	var degraded atomic.Bool
	var lastFailure time.Time // guarded by mu: when an event was last lost
	// loss records that events may have been lost now. When the generation cannot be
	// written the loss is unrecorded, so the receiver counts as degraded and withholds its
	// heartbeat until recovered writes it.
	loss := func() {
		lastFailure = time.Now()
		if anchor.RaiseGeneration(cfg.StateDir, lastFailure) != nil {
			degraded.Store(true)
		}
	}
	apply := func(ev anchor.Event) error {
		mu.Lock()
		defer mu.Unlock()
		_, err := anchor.Apply(cfg.StateDir, ev)
		if err != nil {
			degraded.Store(true)
			loss()
		}
		return err
	}
	// lost is a loss of events that were dropped without being stored.
	lost := func() {
		mu.Lock()
		defer mu.Unlock()
		loss()
	}
	// recovered says state can be written again. The generation it settles on is the time of
	// the last loss, not the time of recovery: an anchor stored since the loss (the exporter
	// resends a refused request) came after it and must not be doubted by it, while what was
	// stored before stays doubted. The generation never moves back, so a later loss recorded
	// meanwhile stands.
	recovered := func(now time.Time) bool {
		mu.Lock()
		defer mu.Unlock()
		if !degraded.Load() {
			return true
		}
		if anchor.Writable(cfg.StateDir) != nil || anchor.RaiseGeneration(cfg.StateDir, lastFailure) != nil {
			return false
		}
		degraded.Store(false)
		return true
	}
	sweep := func(now time.Time) {
		mu.Lock()
		defer mu.Unlock()
		anchor.Sweep(cfg.StateDir, now)
	}
	srv := &http.Server{
		Handler: newHandler(apply, time.Now, func(kind string) {
			say("request failed: " + kind)
			// A request refused as oversized or unreadable is a batch dropped whole, a /login
			// with it, whatever the sender. A process that can post here could also write the
			// anchors, so the cost of a false alarm is an extra "?".
			if kind == logTooLarge || kind == logBadRequest {
				lost()
			}
		}),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
	}
	failed := make(chan error, 1)
	go func() { failed <- srv.Serve(ln) }()
	say("listening on " + ln.Addr().String())
	if cfg.OnListen != nil {
		cfg.OnListen(ln.Addr())
	}

	stop := make(chan struct{})
	defer close(stop)
	go heartbeat(stop, cfg, recovered)
	go sweeper(stop, cfg, sweep)
	replaced := make(chan struct{})
	go watchExecutable(stop, cfg, replaced)

	code := 0
	select {
	case <-ctx.Done():
		say("stopping: signal")
	case <-replaced:
		say("stopping: executable replaced")
		code = exitReplaced
	case <-failed:
		say("stopping: server failed")
		code = exitFailed
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	srv.Shutdown(shutdown)
	return code
}

// loopback accepts only an IP literal that is a loopback address, so the receiver can
// never listen on a network interface.
func loopback(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return false
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// heartbeat touches the file the statusline reads to tell the receiver is alive, unless
// the receiver cannot store anchors: a receiver that hears but cannot write is not one
// whose answers can be trusted.
func heartbeat(stop <-chan struct{}, cfg config, recovered func(time.Time) bool) {
	t := time.NewTicker(cfg.BeatEvery)
	defer t.Stop()
	for {
		select {
		case <-stop:
			return
		case now := <-t.C:
			if recovered(now) {
				_ = anchor.TouchHeartbeat(cfg.StateDir, now)
			}
		}
	}
}

func sweeper(stop <-chan struct{}, cfg config, sweep func(time.Time)) {
	every := cfg.SweepEvery
	if every <= 0 {
		every = time.Hour
	}
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-stop:
			return
		case now := <-t.C:
			sweep(now)
		}
	}
}

// watchExecutable closes replaced once the file at cfg.ExePath is no longer the one the
// process started from: build-binary.sh publishes a new build by renaming it over this
// path, which gives it a new inode.
func watchExecutable(stop <-chan struct{}, cfg config, replaced chan<- struct{}) {
	if cfg.ExePath == "" {
		return
	}
	first, err := os.Stat(cfg.ExePath)
	if err != nil {
		return
	}
	t := time.NewTicker(cfg.WatchEvery)
	defer t.Stop()
	for {
		select {
		case <-stop:
			return
		case <-t.C:
			cur, err := os.Stat(cfg.ExePath)
			if err == nil && (!os.SameFile(first, cur) || !cur.ModTime().Equal(first.ModTime()) || cur.Size() != first.Size()) {
				close(replaced)
				return
			}
		}
	}
}
