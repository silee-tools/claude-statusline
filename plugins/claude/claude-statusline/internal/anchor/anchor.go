// Package anchor holds the per-session Claude account the OTLP receiver learned from
// Claude Code's log events, and the statusline's reading of it.
//
// Claude Code's log events carry user.email on every record, but that value is the
// settings file's current account, not the session's authenticated one. Only two kinds
// of record say anything reliable about a session, so only they become an anchor:
//
//   - a start-only event (managed_settings_resolved, plugin_loaded) is emitted once, as
//     the session begins, and carries the account the settings file held then;
//   - a successful auth event (/login) carries the account just logged in, and a
//     logout carries none.
//
// The first event of a session id created by /clear is a user_prompt, whose email is
// whatever the file holds at that moment, so it never starts an anchor.
//
// Neither kind proves which credentials the session holds. A login anchor was written by
// an event the session itself produced after authenticating, so its account is
// confirmed; a start anchor is only what the settings file held at the start, an estimate.
//
// State lives under <stateDir> = ${XDG_STATE_HOME:-$HOME/.local/state}/claude-statusline:
//
//	otel/sessions/<session.id>.env   the anchor: email=, kind=, ts= (event time, unix ms),
//	                                 seen= (when the receiver stored it, unix ms),
//	                                 gen= (the receiver's generation when it stored it)
//	otel/heartbeat                   touched by the receiver; its mtime says it is alive
//	otel/generation                  the receiver's current generation number
//	pids/<pid>-<startedAt>.env       the anchor a process carries across /clear
//	pids/session-<session.id>.ref    which pid file a session belongs to
//
// Every file is kept 30 days after it was stored or last written, and each directory at
// most 2,000 files: the writer prunes on write, the receiver sweeps all three at start and
// hourly, and a reader ignores an anchor older than that.
package anchor

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/silee-tools/claude-statusline/internal/statefile"
)

// Anchor kinds. start: the account the settings file carried when the session began;
// login: an in-session /login; logout: an in-session /logout.
const (
	KindStart  = "start"
	KindLogin  = "login"
	KindLogout = "logout"
)

// Anchor is one session's latest known account. TS is the event time and Seen the time
// the receiver stored it, both in unix milliseconds. Gen is the receiver's generation
// (see WriteGeneration) when it stored the anchor, 0 for a file that carries none; an
// anchor of an earlier generation may have missed a /login since.
type Anchor struct {
	Email string
	Kind  string
	TS    int64
	Seen  int64
	Gen   int64
}

// Event is the allowed-keys view of one OTLP log record: nothing else the record
// carries reaches this package.
type Event struct {
	Name      string // event.name, with or without the claude_code. prefix
	SessionID string
	Email     string
	Action    string
	Success   string // "true" or "false"
	TS        int64  // unix milliseconds
}

// How much the state directories keep, and the clock the receiver stamps anchors with.
// Variables so tests can shrink them and move time.
var (
	maxFiles  = 2000
	retention = 30 * 24 * time.Hour
	clock     = time.Now
)

const maxEmailBytes = 254

// MaxGeneration is the highest generation anything reads or writes: the generation file, the
// number an anchor carries and what WriteGeneration records. One bound for all of them keeps
// every number the receiver writes a number the reader accepts.
const MaxGeneration = int64(1) << 62

// GenerationRunway is the room a start must leave below MaxGeneration for the generations
// the run itself counts (one per loss). A start whose state is closer to the bound gives up.
const GenerationRunway = int64(1) << 40

// errDamagedGeneration is the generation file holding something that is not a generation.
var errDamagedGeneration = errors.New("anchor: damaged generation file")

// errGenerationExhausted is the state holding a generation too close to MaxGeneration to
// count on from there.
var errGenerationExhausted = errors.New("anchor: generation range exhausted")

// parseGeneration reads the number in an anchor's gen=: a whole number from 0 to
// MaxGeneration. Anything else (not a number, negative, out of range) is not one and counts
// as generation 0, which is doubted, so a damaged anchor neither passes as current nor lifts
// the count.
func parseGeneration(v string) (int64, bool) {
	n, err := strconv.ParseInt(strings.TrimSpace(v), 10, 64)
	if err != nil || n < 0 || n > MaxGeneration {
		return 0, false
	}
	return n, true
}

// NextLoss is the generation after a loss. It stops at MaxGeneration, so the receiver never
// stamps a number the reader would not accept.
func NextLoss(gen int64) (int64, bool) {
	if gen >= MaxGeneration {
		return gen, false
	}
	return gen + 1, true
}

func sessionsDir(stateDir string) string { return filepath.Join(stateDir, "otel", "sessions") }

// validID accepts the characters a session id can carry and nothing that could leave
// the directory or break the line format.
func validID(id string) bool {
	if id == "" || len(id) > 64 {
		return false
	}
	for i := 0; i < len(id); i++ {
		c := id[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

func validEmail(s string) bool {
	if s == "" || len(s) > maxEmailBytes || !utf8.ValidString(s) {
		return false
	}
	for _, r := range s {
		if r < 0x20 || r == 0x7f {
			return false
		}
	}
	return true
}

// Apply folds one event into the session's anchor, stamped with the receiver's generation
// gen, and reports whether it wrote one. Callers serialize Apply: it reads the stored
// anchor before replacing it.
//
// A start-only event counts only when the session has no anchor yet, and an event
// older than the stored one is dropped, so events arriving out of order leave the
// anchor of the latest event.
func Apply(stateDir string, ev Event, gen int64) (bool, error) {
	if !validID(ev.SessionID) {
		return false, nil
	}
	next := Anchor{TS: ev.TS, Seen: clock().UnixMilli(), Gen: gen}
	switch strings.TrimPrefix(ev.Name, "claude_code.") {
	case "managed_settings_resolved", "plugin_loaded":
		next.Kind = KindStart
	case "auth":
		switch {
		case ev.Action == "login" && ev.Success == "true":
			next.Kind = KindLogin
		case ev.Action == "logout" && ev.Success != "false":
			next.Kind = KindLogout
		default:
			return false, nil
		}
	default:
		return false, nil
	}
	if next.Kind != KindLogout {
		if !validEmail(ev.Email) {
			return false, nil
		}
		next.Email = ev.Email
	}
	if cur, has := readFresh(stateDir, ev.SessionID, clock()); has && (next.Kind == KindStart || next.TS < cur.TS) {
		return false, nil
	}
	dir := sessionsDir(stateDir)
	if err := statefile.Write(filepath.Join(dir, ev.SessionID+".env"), encode(next)); err != nil {
		return false, err
	}
	statefile.Prune(dir, clock(), retention, maxFiles)
	return true, nil
}

func encode(a Anchor) []byte {
	return []byte("email=" + a.Email + "\nkind=" + a.Kind + "\nts=" + strconv.FormatInt(a.TS, 10) +
		"\nseen=" + strconv.FormatInt(a.Seen, 10) + "\ngen=" + strconv.FormatInt(a.Gen, 10) + "\n")
}

// Read returns the anchor of session id. A missing or damaged file is no anchor.
func Read(stateDir, id string) (Anchor, bool) {
	if !validID(id) {
		return Anchor{}, false
	}
	b, err := os.ReadFile(filepath.Join(sessionsDir(stateDir), id+".env"))
	if err != nil {
		return Anchor{}, false
	}
	return decode(string(b))
}

func decode(s string) (Anchor, bool) {
	var a Anchor
	for _, line := range strings.Split(s, "\n") {
		k, v, found := strings.Cut(line, "=")
		if !found {
			continue
		}
		switch k {
		case "email":
			a.Email = v
		case "kind":
			a.Kind = v
		case "ts":
			a.TS, _ = strconv.ParseInt(v, 10, 64)
		case "seen":
			a.Seen, _ = strconv.ParseInt(v, 10, 64)
		case "gen":
			a.Gen, _ = parseGeneration(v) // a number that is not one counts as generation 0
		}
	}
	switch a.Kind {
	case KindStart, KindLogin:
		if !validEmail(a.Email) {
			return Anchor{}, false
		}
	case KindLogout:
		a.Email = ""
	default:
		return Anchor{}, false
	}
	if a.TS <= 0 {
		return Anchor{}, false
	}
	return a, true
}

// stored is when the receiver wrote the anchor, or its event time for a file that carries
// no seen=.
func (a Anchor) stored() int64 {
	if a.Seen > 0 {
		return a.Seen
	}
	return a.TS
}

// expired reports whether the anchor is older than the retention, so a file the writer has
// not got round to pruning is not used.
func (a Anchor) expired(now time.Time) bool {
	return now.UnixMilli()-a.stored() > retention.Milliseconds()
}

// readFresh is Read without an anchor past its retention.
func readFresh(stateDir, id string, now time.Time) (Anchor, bool) {
	a, ok := Read(stateDir, id)
	if !ok || a.expired(now) {
		return Anchor{}, false
	}
	return a, true
}

func generationPath(stateDir string) string { return filepath.Join(stateDir, "otel", "generation") }

// WriteGeneration records the receiver's generation. The receiver moves to the next one
// when it begins a new stretch of listening or may have lost events (a restart, a failed
// write, a request it dropped). An anchor stamped with an earlier generation cannot be
// told from one a lost /login left behind, so a reader doubts it until a later event
// replaces it.
//
// A generation is a number, not a time, so no reading of the clock can put it behind the
// anchors it has to outrank. It is a positive number up to MaxGeneration, so a negative or
// overflowed one is never recorded.
func WriteGeneration(stateDir string, gen int64) error {
	if gen <= 0 || gen > MaxGeneration {
		return errors.New("anchor: generation out of range")
	}
	return statefile.Write(generationPath(stateDir), []byte(strconv.FormatInt(gen, 10)+"\n"))
}

// NextGeneration is the generation of a receiver that starts now: one past the highest the
// state records, whether in the generation file or in an anchor (the receiver counts a
// loss it could not write down, and stamps anchors with that count). Counting from the
// anchors as well keeps every anchor already stored in an earlier generation when the file
// is missing or behind.
//
// It answers only when it has seen all of that state. A directory or file that does not
// exist counts as empty; one that cannot be listed or read, or a generation file that holds
// no generation, is an error, because a number chosen without it could fall behind an
// anchor and let that anchor pass as current. The scan reads what a reader would: an
// entry that is a directory is not an anchor, a link is followed, and one that vanished
// meanwhile is skipped.
func NextGeneration(stateDir string) (int64, error) {
	top, err := loadGeneration(stateDir)
	if err != nil {
		return 0, err
	}
	for _, dir := range []string{sessionsDir(stateDir), filepath.Join(stateDir, "pids")} {
		entries, err := os.ReadDir(dir)
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				continue
			}
			return 0, err
		}
		for _, e := range entries {
			if e.IsDir() || !strings.HasSuffix(e.Name(), ".env") {
				continue
			}
			b, err := os.ReadFile(filepath.Join(dir, e.Name()))
			if err != nil {
				// A link to a directory is no anchor: the reader cannot read it either.
				if errors.Is(err, fs.ErrNotExist) || errors.Is(err, syscall.EISDIR) {
					continue
				}
				return 0, err
			}
			if a, ok := decode(string(b)); ok && a.Gen > top {
				top = a.Gen
			}
		}
	}
	if top > MaxGeneration-GenerationRunway {
		return 0, errGenerationExhausted
	}
	return top + 1, nil
}

// Withdraw removes the generation and the heartbeat, so that a reader has no generation to
// trust from a new run's first moment until the run has written its own. It reports a file it
// could not remove. It is not what keeps a reader from trusting a stopped receiver: removing
// needs a writable directory, which a failing start may not have, and the receiver's lock
// does that.
func Withdraw(stateDir string) error {
	var first error
	for _, path := range []string{generationPath(stateDir), filepath.Join(stateDir, "otel", "heartbeat")} {
		if err := os.Remove(path); err != nil && !errors.Is(err, fs.ErrNotExist) && first == nil {
			first = err
		}
	}
	return first
}

// Writable reports whether an anchor could be stored now: it writes and removes a probe
// file where the anchors live.
func Writable(stateDir string) error {
	probe := filepath.Join(sessionsDir(stateDir), ".probe")
	if err := statefile.Write(probe, []byte("ok\n")); err != nil {
		return err
	}
	return os.Remove(probe)
}

// loadGeneration returns the generation the file names: 0 when there is no file, an error
// when it cannot be read or holds something that is not a generation (a number from 1 up to
// MaxGeneration).
func loadGeneration(stateDir string) (int64, error) {
	b, err := os.ReadFile(generationPath(stateDir))
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return 0, nil
		}
		return 0, err
	}
	n, err := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
	if err != nil || n <= 0 || n > MaxGeneration {
		return 0, errDamagedGeneration
	}
	return n, nil
}

// readGeneration returns the receiver's current generation. A missing, unreadable or
// damaged file is unknown.
func readGeneration(stateDir string) (int64, bool) {
	n, err := loadGeneration(stateDir)
	return n, err == nil && n > 0
}

// Sweep prunes the state directories to the retention and file limits. The receiver runs
// it at start and hourly, so files of sessions that stopped sending are removed even
// when no new anchor is written.
func Sweep(stateDir string, now time.Time) {
	for _, dir := range []string{sessionsDir(stateDir), filepath.Join(stateDir, "pids"), filepath.Join(stateDir, "fingerprints")} {
		statefile.Prune(dir, now, retention, maxFiles)
	}
}

// TouchHeartbeat records that the receiver is alive at now.
func TouchHeartbeat(stateDir string, now time.Time) error {
	path := filepath.Join(stateDir, "otel", "heartbeat")
	if err := statefile.Write(path, []byte(strconv.FormatInt(now.Unix(), 10)+"\n")); err != nil {
		return err
	}
	return os.Chtimes(path, now, now)
}
