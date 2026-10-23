package anchor

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/silee-tools/claude-statusline/internal/statefile"
)

const (
	// staleHeartbeat is how old the receiver's heartbeat may be before the account is
	// shown with a doubt: it touches the file every 30 seconds.
	staleHeartbeat = 120 * time.Second
	// startSlack is how far before the process start (the sessions file's startedAt) an
	// event may lie and still be the process's: events are exported in batches.
	startSlack = 3000 // ms
)

// alive says whether a process with this pid exists. Claude Code leaves
// <config>/sessions/<pid>.json behind when it dies without cleaning up (a kill, a crash, a
// power loss), so a file alone does not show that its process runs. It is a variable so
// tests can stand in for pids no machine has.
// shortcut: an unrelated process that reuses a dead pid makes its file look alive, which
// the parent-first and latest-start rules narrow but do not close; compare the start time
// with the OS (a process spawn per render) if that ever shows.
var alive = processAlive

func processAlive(pid int) bool {
	if pid <= 0 { // kill(2) would signal a process group
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || err == syscall.EPERM
}

// Confidence says how well the anchor behind an email establishes the account.
type Confidence int

const (
	// Unknown: no anchor ties an account to the session.
	Unknown Confidence = iota
	// Estimate: the account the settings file held when the session began, which is the
	// session's own only while the file and the credentials agree.
	Estimate
	// Confirmed: an in-session /login named the account.
	Confirmed
)

// Input is what Resolve needs to know about one render.
type Input struct {
	StateDir  string
	ConfigDir string // the normalised Claude config directory, whose sessions/ lists its processes
	SessionID string
	Parent    int // the pid of the process that started the statusline, 0 when unknown
	Now       time.Time
}

// Result is what the account slot shows. Installed is false when the receiver has never
// run on this machine, which leaves the slot empty instead of a permanent "?". Email is
// empty when the account cannot be told, and Level says how well it is established.
// Suspect says the account may have changed unseen: the receiver looks stopped, or the
// anchor predates the receiver's current generation. AnchorTS identifies the anchor the
// email came from.
type Result struct {
	Installed bool
	Email     string
	Level     Confidence
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
		r.Level = Estimate
		if a.Kind == KindLogin {
			r.Level = Confirmed
		}
		// An anchor stored before the receiver's current generation may have missed a
		// /login since, and only a later event replaces it.
		if gen, ok := readGeneration(in.StateDir); !ok || a.stored() < gen {
			r.Suspect = true
		}
	}
	return r
}

// Boundary names the stretch of a session in which its rate-limit windows describe one
// account: the process that runs it and the time of its last in-session login or logout.
// Windows kept under another boundary, as when a new process resumes the conversation or
// a /login has changed the account, are not drawn. It is empty when the process cannot be
// told, which leaves nothing to keep.
func Boundary(in Input) string {
	if !validID(in.SessionID) {
		return ""
	}
	p, _, _, ok := locate(in)
	if !ok {
		return ""
	}
	var auth int64
	if a, ok := readFresh(in.StateDir, in.SessionID, in.Now); ok && a.Kind != KindStart && a.TS >= p.started-startSlack {
		auth = a.TS
	}
	return p.key() + "-" + strconv.FormatInt(auth, 10)
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
		if json.Unmarshal(b, &f) != nil || f.PID <= 0 || f.StartedAt <= 0 || !validID(f.SessionID) || !alive(f.PID) {
			continue
		}
		out = append(out, procInfo{proc{f.PID, f.StartedAt}, f.SessionID})
	}
	return out
}

// findProc picks the process that runs session id. A conversation a new process resumes
// is named by the files of both the process that left and the one that took it over; the
// one that started last is the live one, whatever order the directory lists them in.
func findProc(procs []procInfo, id string) (proc, bool) {
	var best proc
	found := false
	for _, p := range procs {
		if p.session == id && (!found || p.started > best.started) {
			best, found = p.proc, true
		}
	}
	return best, found
}

// What the statusline keeps about a process, in pids/<pid>-<startedAt>.env: the session
// id that last rendered and the anchor the process carries. Src is the session the anchor
// came from while the first render under a new id has not yet checked it: once that
// render has, the anchor is the process's and nothing later under the old id reaches it.
type pidFile struct {
	Session string
	Src     string
	Anchor  Anchor
	Has     bool // Anchor is meaningful
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

// readProc reads the one file Claude Code keeps for process pid in configDir. It lists
// nothing and opens no *.key file.
func readProc(configDir string, pid int) (procInfo, bool) {
	b, err := os.ReadFile(filepath.Join(configDir, "sessions", strconv.Itoa(pid)+".json"))
	if err != nil {
		return procInfo{}, false
	}
	var f struct {
		PID       int    `json:"pid"`
		SessionID string `json:"sessionId"`
		StartedAt int64  `json:"startedAt"`
	}
	if json.Unmarshal(b, &f) != nil || f.PID != pid || f.StartedAt <= 0 || !validID(f.SessionID) {
		return procInfo{}, false
	}
	return procInfo{proc{f.PID, f.StartedAt}, f.SessionID}, true
}

// ownsSession reports whether the process still runs under session id: the file Claude
// Code keeps for it must name that id and that start time.
func ownsSession(configDir string, p proc, id string) bool {
	q, ok := readProc(configDir, p.pid)
	return ok && q.session == id && q.started == p.started
}

// locate finds the process that runs session id. The process that started the statusline
// is Claude Code itself, so when its own file names the session that is the strongest
// evidence there is, and one read answers it. Without it, the ref an earlier render left
// is accepted while its process still runs, and last the config directory's processes are
// listed. A process counts only while it runs and its own file names the session. r and
// hasRef describe the ref when it names the process found.
func locate(in Input) (p proc, r ref, hasRef, ok bool) {
	id := in.SessionID
	r, hasRef = readRef(in.StateDir, id)
	if in.Parent > 0 {
		if q, found := readProc(in.ConfigDir, in.Parent); found && q.session == id {
			if !hasRef || r.proc != q.proc {
				r, hasRef = ref{}, false
			}
			return q.proc, r, hasRef, true
		}
	}
	if hasRef && ownsSession(in.ConfigDir, r.proc, id) && alive(r.proc.pid) {
		return r.proc, r, true, true
	}
	p, ok = findProc(scanProcs(in.ConfigDir), id)
	return p, ref{}, false, ok
}

// sessionAnchor finds the anchor of the session: its own, or, after /clear gave the
// process a new session id, the one the process carried.
//
// "Its own" means the anchor of this process. A resumed session reuses the id of the
// conversation it resumes, whose earlier process may have left an anchor under that id;
// an anchor older than this process's start belongs to that earlier process.
//
// A process that resumes a conversation sends its start events under a throwaway session
// id that nothing ties to the process, so a resumed session has no anchor until it
// logs in. The anchors of other session ids are never borrowed on the strength of timing:
// any process of any config directory could have written them.
//
// /clear leaves the anchor under the old id, where another process that resumes that id
// can replace it. The first render under the new id therefore settles the carry once: if
// the old id's anchor is still the one the process carried, the process keeps it for
// good, and if it has changed, whose event changed it cannot be told, so the process has
// no anchor until it logs in.
func sessionAnchor(in Input) (Anchor, bool) {
	id := in.SessionID
	if !validID(id) {
		return Anchor{}, false
	}
	direct, hasDirect := readFresh(in.StateDir, id, in.Now)
	p, r, hasRef, known := locate(in)
	if hasDirect && hasRef && r.ts == direct.TS {
		return direct, true
	}
	if !known {
		return direct, hasDirect
	}
	if hasDirect && direct.TS < p.started-startSlack {
		hasDirect = false
	}
	if hasDirect {
		writePidFile(in.StateDir, in.Now, p, pidFile{Session: id, Src: id, Anchor: direct, Has: true})
		writeRef(in.StateDir, in.Now, id, p, direct.TS)
		return direct, true
	}
	pf := readPidFile(in.StateDir, p)
	if !pf.Has || pf.Anchor.expired(in.Now) {
		return Anchor{}, false
	}
	a := pf.Anchor
	if pf.Session != id {
		pf.Session = id
		if cur, found := readFresh(in.StateDir, pf.Src, in.Now); pf.Src != "" && found && cur != a {
			pf.Has, pf.Anchor = false, Anchor{}
			writePidFile(in.StateDir, in.Now, p, pf)
			return Anchor{}, false
		}
		pf.Src = ""
		writePidFile(in.StateDir, in.Now, p, pf)
	}
	if !hasRef || r.ts != a.TS {
		writeRef(in.StateDir, in.Now, id, p, a.TS)
	}
	return a, true
}
