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
// State lives under <stateDir> = ${XDG_STATE_HOME:-$HOME/.local/state}/claude-statusline:
//
//	otel/sessions/<session.id>.env   the anchor: email=, kind=, ts= (event time, unix ms)
//	otel/heartbeat                   touched by the receiver; its mtime says it is alive
//	pids/<pid>-<startedAt>.env       the anchor a process carries across /clear
//	pids/session-<session.id>.ref    which pid file a session belongs to
//
// Each directory is pruned on write to 30 days and, for otel/sessions and pids, 2,000
// files.
package anchor

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
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

// Anchor is one session's latest known account. TS is the event time in unix
// milliseconds.
type Anchor struct {
	Email string
	Kind  string
	TS    int64
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

// How much the state directories keep. Variables so tests can shrink them.
var (
	maxFiles  = 2000
	retention = 30 * 24 * time.Hour
)

const maxEmailBytes = 254

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

// Apply folds one event into the session's anchor and reports whether it wrote one.
// Callers serialize Apply: it reads the stored anchor before replacing it.
//
// A start-only event counts only when the session has no anchor yet, and an event
// older than the stored one is dropped, so events arriving out of order leave the
// anchor of the latest event.
func Apply(stateDir string, ev Event) (bool, error) {
	if !validID(ev.SessionID) {
		return false, nil
	}
	next := Anchor{TS: ev.TS}
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
	if cur, has := Read(stateDir, ev.SessionID); has && (next.Kind == KindStart || next.TS < cur.TS) {
		return false, nil
	}
	dir := sessionsDir(stateDir)
	if err := statefile.Write(filepath.Join(dir, ev.SessionID+".env"), encode(next)); err != nil {
		return false, err
	}
	statefile.Prune(dir, time.Now(), retention, maxFiles)
	return true, nil
}

func encode(a Anchor) []byte {
	return []byte("email=" + a.Email + "\nkind=" + a.Kind + "\nts=" + strconv.FormatInt(a.TS, 10) + "\n")
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

// TouchHeartbeat records that the receiver is alive at now.
func TouchHeartbeat(stateDir string, now time.Time) error {
	path := filepath.Join(stateDir, "otel", "heartbeat")
	if err := statefile.Write(path, []byte(strconv.FormatInt(now.Unix(), 10)+"\n")); err != nil {
		return err
	}
	return os.Chtimes(path, now, now)
}
