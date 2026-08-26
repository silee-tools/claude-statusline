// Package segments renders the account and session indicators of the identity row.
package segments

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/silee-tools/claude-statusline/internal/theme"
)

// GitHubAccount renders the active GitHub login as a label plus a state marker.
//
// The login and its state come from the cache the shell prompt writes at
// <dataDir>/gh-prompt-user, one tab separated record:
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
func GitHubAccount(dataDir, configDir string, now int64) string {
	b, err := os.ReadFile(filepath.Join(dataDir, "gh-prompt-user"))
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

var offsetColonRe = regexp.MustCompile(`([+-]\d\d):(\d\d)$`)

// AWS renders the saml2aws session state. Without saml2aws on PATH there is no
// session to report and the segment is empty.
//
// AWS_SESSION_EXPIRATION wins when set; otherwise the expiry comes from
// x_security_token_expires in credsFile. Only the file path caches the parsed epoch,
// because an environment value costs nothing to reparse and would make the cache
// disagree with the file.
func AWS(credsFile, dataDir, cacheDir string, now int64) string {
	if _, err := exec.LookPath("saml2aws"); err != nil {
		return ""
	}
	fromEnv := os.Getenv("AWS_SESSION_EXPIRATION")
	exp := fromEnv
	if exp == "" {
		exp = readTokenExpiry(credsFile)
	}
	if exp == "" {
		return theme.Dim + "aws:?" + theme.Reset
	}

	cache := filepath.Join(cacheDir, "aws-exp.env")
	epoch := int64(0)
	if fromEnv == "" {
		credsInfo, credsErr := os.Stat(credsFile)
		cacheInfo, cacheErr := os.Stat(cache)
		if credsErr == nil && cacheErr == nil && !credsInfo.ModTime().After(cacheInfo.ModTime()) {
			if b, err := os.ReadFile(cache); err == nil {
				for _, line := range strings.Split(string(b), "\n") {
					if k, v, found := strings.Cut(line, "="); found && k == "exp_epoch" {
						epoch, _ = strconv.ParseInt(v, 10, 64)
					}
				}
			}
		}
	}
	if epoch == 0 {
		epoch = parseExpiry(exp)
		if fromEnv == "" {
			if _, err := os.Stat(credsFile); err == nil && os.MkdirAll(cacheDir, 0o755) == nil {
				_ = os.WriteFile(cache,
					[]byte("exp_epoch="+strconv.FormatInt(epoch, 10)+"\n"), 0o600)
			}
		}
	}

	remaining := (epoch - now) / 60
	switch {
	case remaining > 10:
		return theme.Green + "aws:✓" + theme.Reset
	case remaining > 0:
		return theme.Yellow + "aws:⏳" + strconv.FormatInt(remaining, 10) + "m" + theme.Reset
	}
	if suppressedToday(dataDir) {
		return theme.Dim + "aws:-" + theme.Reset
	}
	return theme.Red + "aws:expired" + theme.Reset
}

func readTokenExpiry(credsFile string) string {
	b, err := os.ReadFile(credsFile)
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(b), "\n") {
		rest, ok := strings.CutPrefix(line, "x_security_token_expires")
		if !ok {
			continue
		}
		rest = strings.TrimLeft(rest, " ")
		rest, ok = strings.CutPrefix(rest, "=")
		if !ok {
			continue
		}
		return strings.TrimLeft(rest, " ")
	}
	return ""
}

// parseExpiry accepts the numeric-offset form saml2aws writes and, as the shell's
// second date attempt did, the RFC 3339 spellings a "Z" or a fractional second give.
// An unparseable value yields 0, which renders as expired.
func parseExpiry(exp string) int64 {
	if t, err := time.Parse("2006-01-02T15:04:05-0700", offsetColonRe.ReplaceAllString(exp, "$1$2")); err == nil {
		return t.Unix()
	}
	if t, err := time.Parse(time.RFC3339, exp); err == nil {
		return t.Unix()
	}
	return 0
}

func suppressedToday(dataDir string) bool {
	b, err := os.ReadFile(filepath.Join(dataDir, "saml2aws-login-suppress"))
	if err != nil {
		return false
	}
	want := "value=" + time.Now().Format("2006-01-02")
	for _, line := range strings.Split(string(b), "\n") {
		if line == want {
			return true
		}
	}
	return false
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
