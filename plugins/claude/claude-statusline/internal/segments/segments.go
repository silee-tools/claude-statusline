// Package segments renders the account and session indicators of the identity row.
package segments

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/silee-tools/claude-statusline/internal/theme"
)

// GitHubAccount renders the GitHub account gh uses for the repository at repoRoot as a
// label plus a state marker, or "" outside a repository or before the shell has
// recorded one.
//
// The account and its state come from the cache the shell prompt writes at
// <cacheDir>/<repoRoot with / replaced by %>, keyed by the physical root that
// `git rev-parse --show-toplevel` reports. The file holds one tab separated record:
//
//	v2<TAB><login or -><TAB><state><TAB><deadline epoch or 0>
//
// A single line without tabs is a bare login, which is what a prompt that records
// only the login writes. This tool only reads that cache; refreshing it and judging
// its freshness belong to the prompt.
//
// Two orderings matter here. The login is judged before the state, because the
// reverse lets a record with an empty login slot leak out as gh@-. And the color code
// and the deadline accept digits only, so neither the config nor the cache can inject
// an escape sequence.
func GitHubAccount(cacheDir, configDir, repoRoot string, now int64) string {
	if repoRoot == "" {
		return ""
	}
	if physical, err := filepath.EvalSymlinks(repoRoot); err == nil {
		repoRoot = physical
	}
	b, err := os.ReadFile(filepath.Join(cacheDir, strings.ReplaceAll(repoRoot, "/", "%")))
	if err != nil {
		return ""
	}
	line, _, _ := strings.Cut(string(b), "\n")
	f := readFields(line, 5)

	var login, state string
	deadline := int64(0)
	switch {
	case f[1] == "":
		login, state = f[0], "ok"
	case f[3] != "" && f[4] == "":
		login = f[1]
		if f[0] == "v2" {
			state = f[2]
			if n, err := strconv.ParseInt(f[3], 10, 64); err == nil && isDigits(f[3]) {
				deadline = n
			}
		} else {
			state = "unknown"
		}
	default:
		state = "unknown"
	}
	switch state {
	case "ok", "rate_limited", "auth_failed", "unknown", "no_active":
	default:
		state = "unknown"
	}
	login = stripControl(login)

	if login == "" || login == "-" {
		if state == "no_active" {
			return theme.Grey240 + "gh@---" + theme.Reset
		}
		return theme.Grey240 + "gh@?" + theme.Reset
	}

	label, color := lookupAccount(configDir, login)
	base := theme.Amber214
	if isDigits(color) {
		base = theme.Esc + "[38;5;" + color + "m"
	}

	switch state {
	case "auth_failed":
		return theme.Red + "gh@" + label + "!" + theme.Reset
	case "unknown":
		return theme.Grey240 + "gh@" + label + "?" + theme.Reset
	case "no_active":
		return theme.Grey240 + "gh@---" + theme.Reset
	case "rate_limited":
		if deadline > now {
			mins := (deadline - now + 59) / 60
			return base + "gh@" + label + theme.Reset +
				theme.Yellow + "⏳" + strconv.FormatInt(mins, 10) + "m" + theme.Reset
		}
	}
	return base + "gh@" + label + theme.Reset
}

// lookupAccount reads the login to label and color mapping. Account names, labels and
// colors stay out of the source so it can be published: they live in
// <configDir>/claude-statusline/gh-accounts, one "<login>=<label>,<256-color>" per
// line, with # starting a comment.
func lookupAccount(configDir, login string) (label, color string) {
	label = login
	b, err := os.ReadFile(filepath.Join(configDir, "claude-statusline", "gh-accounts"))
	if err != nil {
		return label, ""
	}
	for _, line := range strings.Split(string(b), "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if !strings.HasPrefix(line, login+"=") {
			continue
		}
		_, rest, _ := strings.Cut(line, "=")
		l, c, hasComma := strings.Cut(rest, ",")
		label = stripControl(l)
		if hasComma {
			color = stripControl(c)
		}
		return label, color
	}
	return label, ""
}

// readFields splits a line the way `IFS=<TAB> read -r a b c d e` does: a tab is IFS
// whitespace, so leading and trailing tabs are dropped, runs of tabs collapse into
// one separator, and the last variable takes the remainder verbatim. Splitting on
// every tab instead would read "v2<TAB><TAB>ok<TAB>0" as a bare login record.
func readFields(line string, n int) []string {
	out := make([]string, n)
	s := strings.Trim(line, "\t")
	for i := 0; i < n && s != ""; i++ {
		if i == n-1 {
			out[i] = s
			break
		}
		field, rest, found := strings.Cut(s, "\t")
		out[i] = field
		if !found {
			break
		}
		s = strings.TrimLeft(rest, "\t")
	}
	return out
}

var emailRe = regexp.MustCompile(`"emailAddress"[ \t]*:[ \t]*"([^"]*)"`)
var oauthRe = regexp.MustCompile(`"oauthAccount"[ \t]*:[ \t]*\{`)

// ClaudeAccount renders the logged-in Claude Code account email. The payload carries
// no account information, so it comes from oauthAccount.emailAddress in
// <configDir>/.claude.json.
//
// That file is Claude Code's own runtime state and this tool never writes to it. It
// also runs to hundreds of kilobytes and its projects keys are file paths, so it is
// scanned line by line for the first emailAddress after the oauthAccount opener
// rather than parsed whole. The result is cached and rescanned only once the file is
// newer than the cache, which is when the email could have changed.
func ClaudeAccount(configDir, cacheDir string) string {
	cf := filepath.Join(configDir, ".claude.json")
	cfInfo, err := os.Stat(cf)
	if err != nil || !cfInfo.Mode().IsRegular() {
		return ""
	}
	cache := filepath.Join(cacheDir, "cc-account.env")

	email, cached := "", false
	if cacheInfo, err := os.Stat(cache); err == nil && !cfInfo.ModTime().After(cacheInfo.ModTime()) {
		if b, err := os.ReadFile(cache); err == nil {
			for _, line := range strings.Split(string(b), "\n") {
				if k, v, found := strings.Cut(line, "="); found && k == "email" {
					email = v
				}
			}
			cached = true
		}
	}
	if !cached {
		email = stripControl(scanEmail(cf))
		if os.MkdirAll(cacheDir, 0o755) == nil {
			_ = os.WriteFile(cache, []byte("email="+email+"\n"), 0o600)
		}
	}
	if email == "" {
		return ""
	}
	return theme.Coral173 + email + theme.Reset
}

func scanEmail(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	inBlock := false
	for _, line := range strings.Split(string(b), "\n") {
		if oauthRe.MatchString(line) {
			inBlock = true
		}
		if !inBlock {
			continue
		}
		if m := emailRe.FindStringSubmatch(line); m != nil {
			return m[1]
		}
	}
	return ""
}

// awsAccessTTL is how long the access credentials in the login cache stay valid; `aws`
// rewrites the cache (and its idToken iat) only when a call refreshes them.
const awsAccessTTL = 15 * 60

// awsCheckTTL is how long the last background check stands before the next one.
const awsCheckTTL = 10 * 60

// awsCheckScript asks AWS whether the login still works and records "<epoch> ok|fail"
// in $1. It uses AWS_PROFILE, else the first profile in the config with a login_session.
// A success also makes `aws` refresh the login cache. ponytail: a network outage reads
// as fail, add an exit-code split if that proves noisy.
const awsCheckScript = `p=${AWS_PROFILE:-$(awk '/^\[profile /{n=$2;sub(/\]/,"",n)} /^login_session/{print n;exit}' "${AWS_CONFIG_FILE:-$HOME/.aws/config}" 2>/dev/null)}
if aws ${p:+--profile "$p"} sts get-caller-identity >/dev/null 2>&1; then r=ok; else r=fail; fi
printf '%s %s\n' "$(date +%s)" "$r" > "$1.$$" && mv "$1.$$" "$1"`

// SpawnAWSCheck runs awsCheckScript detached, so the render never waits for AWS.
func SpawnAWSCheck(stateFile string) {
	cmd := exec.Command("sh", "-c", awsCheckScript, "sh", stateFile)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if cmd.Start() == nil {
		go cmd.Wait()
	}
}

// AWS renders the `aws login` session state, or "" without a login cache. healthy is
// true only for aws:✓, which the narrow layout leaves out.
//
// The newest *.json in loginCacheDir is the active session. Its idToken iat is the time
// of the last credential refresh, not of the login, so a recent iat proves a live login
// and an old one proves nothing. Then the last background check decides, kept in
// stateFile as "<epoch> ok|fail". A check older than awsCheckTTL is renewed through
// spawn; the state file is stamped first so concurrent renders spawn only once.
func AWS(loginCacheDir, stateFile string, now int64, spawn func(stateFile string)) (text string, healthy bool) {
	path, ok := newestCacheFile(loginCacheDir)
	if !ok {
		return "", false
	}
	iat, ok := awsLoginTime(path)
	if !ok {
		return theme.Dim + "aws:?" + theme.Reset, false
	}
	if now-iat < awsAccessTTL {
		return theme.Green + "aws:✓" + theme.Reset, true
	}
	checked, result := readAWSCheck(stateFile)
	if now-checked >= awsCheckTTL {
		writeAWSCheck(stateFile, now, result)
		spawn(stateFile)
	}
	switch result {
	case "ok":
		return theme.Green + "aws:✓" + theme.Reset, true
	case "fail":
		return theme.Red + "aws:expired" + theme.Reset, false
	}
	return theme.Dim + "aws:?" + theme.Reset, false
}

func readAWSCheck(file string) (int64, string) {
	b, err := os.ReadFile(file)
	if err != nil {
		return 0, ""
	}
	f := strings.Fields(string(b))
	if len(f) != 2 {
		return 0, ""
	}
	at, err := strconv.ParseInt(f[0], 10, 64)
	if err != nil {
		return 0, ""
	}
	return at, f[1]
}

func writeAWSCheck(file string, at int64, result string) {
	if result == "" {
		result = "?"
	}
	os.MkdirAll(filepath.Dir(file), 0o755)
	tmp := file + ".tmp"
	if os.WriteFile(tmp, []byte(strconv.FormatInt(at, 10)+" "+result+"\n"), 0o600) == nil {
		os.Rename(tmp, file)
	}
}

// awsLoginTime reads iat from the JWT payload of the cache file's idToken.
func awsLoginTime(path string) (int64, bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0, false
	}
	var cache struct {
		IDToken string `json:"idToken"`
	}
	if json.Unmarshal(b, &cache) != nil {
		return 0, false
	}
	parts := strings.Split(cache.IDToken, ".")
	if len(parts) != 3 {
		return 0, false
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return 0, false
	}
	var claims struct {
		IAT int64 `json:"iat"`
	}
	if json.Unmarshal(payload, &claims) != nil || claims.IAT <= 0 {
		return 0, false
	}
	return claims.IAT, true
}

// newestCacheFile returns the *.json entry in dir with the latest mtime.
func newestCacheFile(dir string) (string, bool) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", false
	}
	var path string
	var newest time.Time
	found := false
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		if !found || info.ModTime().After(newest) {
			path = filepath.Join(dir, e.Name())
			newest = info.ModTime()
			found = true
		}
	}
	return path, found
}

func isDigits(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

func stripControl(s string) string {
	return strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, s)
}
