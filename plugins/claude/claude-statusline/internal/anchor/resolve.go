package anchor

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/silee-tools/claude-statusline/internal/statefile"
)

const (
	// staleHeartbeat is how old the receiver's heartbeat may be before the account is
	// shown with a doubt: it touches the file every 30 seconds.
	staleHeartbeat = 120 * time.Second
	// minProcessAge is how long a process must have run before the search for its
	// resumed session's start anchor, which only arrives after the log export interval.
	minProcessAge = 8 * time.Second
	// startSlack is how far a start anchor's event time may lie from the process start
	// (the sessions file's startedAt) to count as that process's.
	startSlack = 3000 // ms
)

// Input is what Resolve needs to know about one render.
type Input struct {
	StateDir  string
	ConfigDir string // the normalised Claude config directory, whose sessions/ lists its processes
	SessionID string
	Now       time.Time
}

// Result is what the account slot shows. Installed is false when the receiver has never
// run on this machine, which leaves the slot empty instead of a permanent "?". Email is
// empty when the account cannot be told. Suspect says the receiver looks stopped, so a
// /login may have gone unseen. AnchorTS identifies the anchor the email came from.
type Result struct {
	Installed bool
	Email     string
	Suspect   bool
	AnchorTS  int64
}

// Resolve tells which account the session is logged in as, from the anchors alone: no
// settings file is read.
func Resolve(in Input) Result {
	if info, err := os.Stat(sessionsDir(in.StateDir)); err != nil || !info.IsDir() {
		return Result{}
	}
	r := Result{Installed: true}
	hb, err := os.Stat(filepath.Join(in.StateDir, "otel", "heartbeat"))
	r.Suspect = err != nil || in.Now.Sub(hb.ModTime()) > staleHeartbeat
	if a, ok := sessionAnchor(in); ok && a.Email != "" {
		r.Email, r.AnchorTS = a.Email, a.TS
	}
	return r
}

// A process is told apart by its pid and start time together, which no later process
// reuses. Claude Code keeps <config>/sessions/<pid>.json for each running process, with
// the current sessionId: /clear changes the id and leaves the pid and startedAt alone.
type proc struct {
	pid     int
	started int64 // unix milliseconds
}

func (p proc) key() string { return strconv.Itoa(p.pid) + "-" + strconv.FormatInt(p.started, 10) }

func parseProc(key string) (proc, bool) {
	pid, started, found := strings.Cut(key, "-")
	var p proc
	var err1, err2 error
	p.pid, err1 = strconv.Atoi(pid)
	p.started, err2 = strconv.ParseInt(started, 10, 64)
	return p, found && err1 == nil && err2 == nil && p.pid > 0 && p.started > 0
}

type procInfo struct {
	proc
	session string
}

// scanProcs lists the running processes of the config directory. Only *.json files are
// opened: the directory also holds *.key files, which are secrets.
func scanProcs(configDir string) []procInfo {
	dir := filepath.Join(configDir, "sessions")
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out []procInfo
	for _, e := range ents {
		if !e.Type().IsRegular() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		b, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			continue
		}
		var f struct {
			PID       int    `json:"pid"`
			SessionID string `json:"sessionId"`
			StartedAt int64  `json:"startedAt"`
		}
		if json.Unmarshal(b, &f) != nil || f.PID <= 0 || f.StartedAt <= 0 || !validID(f.SessionID) {
			continue
		}
		out = append(out, procInfo{proc{f.PID, f.StartedAt}, f.SessionID})
	}
	return out
}

func findProc(procs []procInfo, id string) (proc, bool) {
	for _, p := range procs {
		if p.session == id {
			return p.proc, true
		}
	}
	return proc{}, false
}

// What the statusline keeps about a process, in pids/<pid>-<startedAt>.env: the session
// id that last rendered, the anchor the process carries (and the session it came from),
// and whether the search for a resumed session's start anchor already ran.
type pidFile struct {
	Session string
	Src     string
	Anchor  Anchor
	Has     bool // Anchor is meaningful
	Checked bool
}

func pidPath(stateDir string, p proc) string {
	return filepath.Join(stateDir, "pids", p.key()+".env")
}

func refPath(stateDir, id string) string {
	return filepath.Join(stateDir, "pids", "session-"+id+".ref")
}

func readPidFile(stateDir string, p proc) pidFile {
	b, err := os.ReadFile(pidPath(stateDir, p))
	if err != nil {
		return pidFile{}
	}
	var f pidFile
	for _, line := range strings.Split(string(b), "\n") {
		switch k, v, _ := strings.Cut(line, "="); k {
		case "session":
			f.Session = v
		case "src":
			f.Src = v
		case "checked":
			f.Checked = v == "1"
		}
	}
	f.Anchor, f.Has = decode(string(b))
	return f
}

func writePidFile(stateDir string, now time.Time, p proc, f pidFile) {
	body := "session=" + f.Session + "\nsrc=" + f.Src + "\n"
	if f.Has {
		body += string(encode(f.Anchor))
	}
	if f.Checked {
		body += "checked=1\n"
	}
	prunedWrite(stateDir, now, pidPath(stateDir, p), body)
}

// A ref tells a session which pid file is its process's, so a steady render reads two
// small files and never lists the sessions directory. ts is the anchor time the pid file
// was last brought up to.
type ref struct {
	proc proc
	ts   int64
}

func readRef(stateDir, id string) (ref, bool) {
	b, err := os.ReadFile(refPath(stateDir, id))
	if err != nil {
		return ref{}, false
	}
	var r ref
	ok := false
	for _, line := range strings.Split(string(b), "\n") {
		switch k, v, _ := strings.Cut(line, "="); k {
		case "proc":
			r.proc, ok = parseProc(v)
		case "ts":
			r.ts, _ = strconv.ParseInt(v, 10, 64)
		}
	}
	return r, ok
}

func writeRef(stateDir string, now time.Time, id string, p proc, ts int64) {
	prunedWrite(stateDir, now, refPath(stateDir, id), "proc="+p.key()+"\nts="+strconv.FormatInt(ts, 10)+"\n")
}

func prunedWrite(stateDir string, now time.Time, path, body string) {
	if statefile.Write(path, []byte(body)) == nil {
		statefile.Prune(filepath.Join(stateDir, "pids"), now, retention, maxFiles)
	}
}

// ownsSession reports whether the process still runs under session id: the file Claude
// Code keeps for it must name that id and that start time. It reads the one file and
// lists nothing.
func ownsSession(configDir string, p proc, id string) bool {
	b, err := os.ReadFile(filepath.Join(configDir, "sessions", strconv.Itoa(p.pid)+".json"))
	if err != nil {
		return false
	}
	var f struct {
		SessionID string `json:"sessionId"`
		StartedAt int64  `json:"startedAt"`
	}
	return json.Unmarshal(b, &f) == nil && f.SessionID == id && f.StartedAt == p.started
}

// sessionAnchor finds the anchor of the session: its own, or, after /clear gave the
// process a new session id, the one the process carried; for a resumed session, the start
// anchor of the throwaway id its start events were sent under.
//
// "Its own" means the anchor of this process. A resumed session reuses the id of the
// conversation it resumes, whose earlier process may have left an anchor and a ref under
// that id; an anchor older than this process's start belongs to that earlier process.
func sessionAnchor(in Input) (Anchor, bool) {
	id := in.SessionID
	if !validID(id) {
		return Anchor{}, false
	}
	direct, hasDirect := Read(in.StateDir, id)
	r, hasRef := readRef(in.StateDir, id)
	if hasRef && !ownsSession(in.ConfigDir, r.proc, id) {
		hasRef = false
	}
	if hasDirect && hasRef && r.ts == direct.TS {
		return direct, true
	}

	var procs []procInfo
	p, known := r.proc, hasRef
	if !hasRef {
		procs = scanProcs(in.ConfigDir)
		p, known = findProc(procs, id)
	}
	if !known {
		return direct, hasDirect
	}
	if hasDirect && direct.TS < p.started-startSlack {
		hasDirect = false
	}
	pf := readPidFile(in.StateDir, p)

	if hasDirect {
		writePidFile(in.StateDir, in.Now, p, pidFile{Session: id, Src: id, Anchor: direct, Has: true})
		writeRef(in.StateDir, in.Now, id, p, direct.TS)
		return direct, true
	}
	if pf.Has {
		a := pf.Anchor
		// The session this anchor came from may have logged in again since the last
		// render saw it.
		if pf.Src != id {
			if s, ok := Read(in.StateDir, pf.Src); ok && s.TS > a.TS {
				a = s
			}
		}
		if pf.Session != id || a != pf.Anchor {
			pf.Session, pf.Anchor = id, a
			writePidFile(in.StateDir, in.Now, p, pf)
		}
		if !hasRef || r.ts != a.TS {
			writeRef(in.StateDir, in.Now, id, p, a.TS)
		}
		return a, true
	}
	if pf.Checked {
		if !hasRef {
			writeRef(in.StateDir, in.Now, id, p, 0)
		}
		return Anchor{}, false
	}
	if in.Now.UnixMilli()-p.started < minProcessAge.Milliseconds() {
		return Anchor{}, false
	}
	if procs == nil {
		procs = scanProcs(in.ConfigDir)
	}
	a, src, ok := adoptOrphan(in, p, procs)
	writePidFile(in.StateDir, in.Now, p, pidFile{Session: id, Src: src, Anchor: a, Has: ok, Checked: true})
	writeRef(in.StateDir, in.Now, id, p, a.TS)
	return a, ok
}

// adoptOrphan looks for the start anchor of a resumed session. --resume and --continue
// send their start events under a throwaway session id, and the real id appears only
// with the first prompt, so the two are tied together by time: the anchors that are
// start anchors, belong to no running process of this config directory, and have an
// event time within startSlack of the process start. The process takes their account
// only when every such anchor names the same one.
func adoptOrphan(in Input, p proc, procs []procInfo) (Anchor, string, bool) {
	alive := make(map[string]bool, len(procs))
	for _, q := range procs {
		alive[q.session] = true
	}
	ents, err := os.ReadDir(sessionsDir(in.StateDir))
	if err != nil {
		return Anchor{}, "", false
	}
	// An anchor is written no earlier than its event time, so older files cannot match.
	floor := time.UnixMilli(p.started - startSlack)
	var found Anchor
	var src string
	for _, e := range ents {
		id, isEnv := strings.CutSuffix(e.Name(), ".env")
		if !isEnv || !e.Type().IsRegular() || alive[id] {
			continue
		}
		if info, err := e.Info(); err != nil || info.ModTime().Before(floor) {
			continue
		}
		a, ok := Read(in.StateDir, id)
		if !ok || a.Kind != KindStart || a.TS < p.started-startSlack || a.TS > p.started+startSlack {
			continue
		}
		switch {
		case src == "":
			found, src = a, id
		case a.Email != found.Email:
			return Anchor{}, "", false
		}
	}
	return found, src, src != ""
}
