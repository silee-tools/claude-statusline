// Command claude-statusline-otlp receives Claude Code's OpenTelemetry log events on a
// loopback port and keeps, per session, the account the statusline shows.
//
// It stores no event: for each session id it writes the latest anchor (see internal/anchor)
// and a heartbeat the statusline reads to tell whether anyone is listening. stderr carries
// only what happened (start, stop, failure kinds), never a value from a request.
//
// Anything it could not store makes it answer 503 so the exporter retries, moves to the next
// generation (otel/generation, a counter) so the anchors it holds are doubted, and stops
// touching the heartbeat until a write succeeds again. Every start moves to the next
// generation too, because a /login that arrived while it was down is lost. A request it
// refused or could not read to the end moves it on as well, and otel/losses keeps why for the
// last 20. Once an hour it removes what is past retention.
//
// Exit codes: 0 after SIGINT or SIGTERM; 75 when the executable at its own path was
// replaced, so a supervisor that restarts on failure brings up the new build; 1 when the
// address is not a loopback address, the port cannot be bound, the state directory cannot be
// prepared or read, another receiver holds the lock, or a lock file was removed or replaced
// under a running receiver. The lock the receiver holds while it runs is what tells the
// statusline a receiver is there, so a start that gives up leaves none to trust.
package main

import (
	"context"
	"errors"
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

// Read limits of the server. The receiver is loopback-only and a body is at most 1 MiB, so a
// slow sender costs little, while a receiver that was starved for longer than the limit would
// cut off a sender that did nothing wrong.
const (
	serverReadHeaderTimeout = 30 * time.Second
	serverReadTimeout       = 60 * time.Second
)

type config struct {
	Addr       string
	StateDir   string
	ExePath    string // the file whose replacement stops the receiver; "" disables the check
	WatchEvery time.Duration
	BeatEvery  time.Duration
	SweepEvery time.Duration // how often to remove state past retention; 0 means hourly
	OnListen   func(net.Addr)
	OnLocked   func() // tests: called once the start lock is held, before any state is touched
	// AfterGuard is called, with the kind of write about to follow, once the locks were found
	// still in place and before the write: the gap tests hold open to replace the lock files
	// in it.
	AfterGuard func(op string)
	// ReadTimeout replaces serverReadTimeout when it is above 0: tests stall a body for less
	// than a minute.
	ReadTimeout time.Duration
}

func main() {
	addr := flag.String("addr", anchor.DefaultAddr, "loopback address to listen on (an IP literal)")
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
	// The start lock keeps a second receiver out; the live lock, taken last, tells the
	// statusline this one is ready. Both go with the process however it ends, so a start that
	// fails below, even one that cannot write anything, leaves no receiver for a reader to
	// trust. Another receiver holding either (one on another port) keeps its state: nothing is
	// touched.
	run, err := anchor.NewRun() // this start, as everything it stores and the live lock name it
	if err != nil {
		say("run id unavailable")
		return exitFailed
	}
	lock, err := anchor.LockReceiver(cfg.StateDir)
	if err != nil {
		if errors.Is(err, anchor.ErrReceiverRunning) {
			say("another receiver is running")
		} else {
			say("lock unavailable")
		}
		return exitFailed
	}
	defer lock.Close()
	if cfg.OnLocked != nil {
		cfg.OnLocked()
	}
	// The previous run's generation, heartbeat and anchors stay out of a reader's sight until
	// this run is ready by the live lock, so Withdraw only clears what a count must not start
	// from: a damaged or unreadable generation file.
	if err := anchor.Withdraw(cfg.StateDir); err != nil {
		say("state unavailable")
		return exitFailed
	}
	anchor.RemoveLosses(cfg.StateDir)
	// Events sent while no receiver ran are gone, so every anchor stored before this
	// start is doubted until a later event replaces it: this run's generation is past every
	// number the state holds, which no setting of the clock changes.
	gen, err := anchor.NextGeneration(cfg.StateDir) // guarded by mu once the server runs
	if err != nil {
		say("generation unavailable")
		return exitFailed
	}
	if err := anchor.WriteGeneration(cfg.StateDir, gen, run); err != nil {
		say("generation unavailable")
		return exitFailed
	}
	// The heartbeat comes last of the state, and the live lock after it: the run is ready. Ready
	// takes the lock only over state that is this run's, and the files are checked once more
	// before anything is served, since a lock file can be replaced between the start and here.
	if err := anchor.TouchHeartbeat(cfg.StateDir, time.Now()); err != nil {
		say("heartbeat unavailable")
		return exitFailed
	}
	if err := lock.Ready(anchor.Receiver{Run: run, Addr: ln.Addr().String()}); err != nil {
		say(readyFailure(err))
		return exitFailed
	}
	if lock.Held() != nil {
		say("lock file removed or replaced")
		return exitFailed
	}
	anchor.Sweep(cfg.StateDir, time.Now())

	// guard says the locks are still on the files at their paths. If a lock file was removed or
	// replaced, another receiver can lock the new one and write the same state, so this one
	// writes nothing more and stops. The check and the write after it are two steps: a receiver
	// held up between them writes once more, which is why everything it stores carries its run
	// and a reader trusts only the run that holds the live lock.
	lockLost := make(chan struct{})
	var lostOnce sync.Once
	guard := func(op string) bool {
		if lock.Held() != nil {
			lostOnce.Do(func() { close(lockLost) })
			return false
		}
		if cfg.AfterGuard != nil {
			cfg.AfterGuard(op)
		}
		return true
	}

	// Apply reads the stored anchor before replacing it, so concurrent requests take turns.
	var mu sync.Mutex
	var degraded atomic.Bool
	var losses lossRecord // guarded by mu
	// loss records that events may have been lost: the receiver moves to the next generation
	// and notes why in otel/losses, a diagnosis whose write failing changes nothing else.
	// When the number cannot be written the loss is unrecorded, so the receiver counts as
	// degraded and withholds its heartbeat until recovered writes it. The count in memory
	// still moves, so an anchor stored from now on is of the later generation.
	loss := func(kind, cause string, bytes int64) {
		if !guard("loss") {
			degraded.Store(true)
			return
		}
		next, ok := anchor.NextLoss(gen)
		if !ok { // no number is left to count with: stay degraded rather than stamp one the reader refuses
			degraded.Store(true)
			return
		}
		gen = next
		if anchor.WriteGeneration(cfg.StateDir, gen, run) != nil {
			degraded.Store(true)
		}
		_ = anchor.WriteLosses(cfg.StateDir, losses.add(time.Now(), gen, kind, cause, bytes))
	}
	apply := func(ev anchor.Event) error {
		mu.Lock()
		defer mu.Unlock()
		if !guard("apply") {
			return anchor.ErrLockLost
		}
		_, err := anchor.Apply(cfg.StateDir, ev, gen, run)
		if err != nil {
			degraded.Store(true)
			loss(logApplyFailed, causeApply, -1) // the record is all this closure sees of the request
		}
		return err
	}
	// lost is a loss of events that were dropped without being stored.
	lost := func(kind, cause string, bytes int64) {
		mu.Lock()
		defer mu.Unlock()
		loss(kind, cause, bytes)
	}
	// recovered says state can be written again, and writes the generation the receiver has
	// counted to. That is the generation of the last loss, not a new one: an anchor stored
	// since the loss (the exporter resends a refused request) carries it and is not doubted,
	// while what was stored before stays doubted. The count only grows, so a later loss
	// recorded meanwhile stands. It also puts the receiver's own generation file back when
	// something else left a different one there (a late write of a receiver that was
	// replaced), which a reader answers with a doubt of every account until it is mended.
	recovered := func(now time.Time) bool {
		mu.Lock()
		defer mu.Unlock()
		if !guard("recovered") {
			return false
		}
		if !degraded.Load() && anchor.GenerationIs(cfg.StateDir, gen, run) {
			return true
		}
		if anchor.Writable(cfg.StateDir) != nil || anchor.WriteGeneration(cfg.StateDir, gen, run) != nil {
			return false
		}
		degraded.Store(false)
		return true
	}
	sweep := func(now time.Time) {
		mu.Lock()
		defer mu.Unlock()
		if !guard("sweep") {
			return
		}
		anchor.Sweep(cfg.StateDir, now)
	}
	readTimeout := serverReadTimeout
	if cfg.ReadTimeout > 0 {
		readTimeout = cfg.ReadTimeout
	}
	srv := &http.Server{
		Handler: newHandler(apply, time.Now, func(kind, cause string, bytes int64) {
			say("request failed: " + kind)
			// A request refused as oversized, unreadable or compressed, or whose body never
			// arrived, is a batch dropped whole, a /login with it, whatever the sender. A process
			// that can post here could also write the anchors, so the cost of a false alarm is an
			// extra "?". A request of another media type is not counted: Claude Code is pinned to
			// JSON, so it is some other exporter's, and one that kept sending would hold every
			// account in doubt.
			if kind == logTooLarge || kind == logBadRequest || kind == logUnreadableEncoding || kind == logReadFailed {
				lost(kind, cause, bytes)
			}
		}),
		ReadHeaderTimeout: serverReadHeaderTimeout,
		ReadTimeout:       readTimeout,
	}
	failed := make(chan error, 1)
	go func() { failed <- srv.Serve(ln) }()
	say("listening on " + ln.Addr().String())
	if cfg.OnListen != nil {
		cfg.OnListen(ln.Addr())
	}

	// serve returns only after the workers stopped, so nothing writes the state after it.
	stop := make(chan struct{})
	var workers sync.WaitGroup
	defer workers.Wait()
	defer close(stop)
	work := func(f func()) {
		workers.Add(1)
		go func() { defer workers.Done(); f() }()
	}
	work(func() { heartbeat(stop, cfg, recovered) })
	work(func() { sweeper(stop, cfg, sweep) })
	replaced := make(chan struct{})
	work(func() { watchExecutable(stop, cfg, replaced) })

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
	case <-lockLost:
		say("stopping: lock file removed or replaced")
		code = exitFailed
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	srv.Shutdown(shutdown)
	return code
}

// readyFailure names why a start could not become ready, for whoever runs the receiver by hand
// to see what stopped it: a supervised run writes its standard error to /dev/null.
func readyFailure(err error) string {
	switch {
	case errors.Is(err, anchor.ErrReceiverRunning):
		return "live lock is held" // by another receiver, or by a process that probes it without letting go
	case errors.Is(err, anchor.ErrLockLost):
		return "lock file removed or replaced"
	case errors.Is(err, anchor.ErrNotReady):
		return "state to publish is not this run's"
	default:
		return "lock unavailable"
	}
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
