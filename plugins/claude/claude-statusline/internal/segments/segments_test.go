package segments

import (
	"encoding/base64"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/silee-tools/claude-statusline/internal/theme"
)

var ansiRe = regexp.MustCompile(`\x1b\[[0-9;]*m`)

func plain(s string) string { return ansiRe.ReplaceAllString(s, "") }

// ghRoot does not exist on disk, so its cache file name is the path with / replaced by %.
const (
	ghRoot = "/repo/fixture"
	ghKey  = "%repo%fixture"
)

// ghFixture writes the prompt cache for ghRoot and the label mapping the segment reads.
func ghFixture(t *testing.T, cache string) (cacheDir, configDir string) {
	t.Helper()
	cacheDir, configDir = t.TempDir(), t.TempDir()
	if err := os.WriteFile(filepath.Join(cacheDir, ghKey), []byte(cache), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(configDir, "claude-statusline"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(configDir, "claude-statusline", "gh-accounts"),
		[]byte("# comment\noctocat=personal,214\ntestwork=work,27\nbadcolor=weird,zz\nescape=lbl,1m\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return cacheDir, configDir
}

// 기대값은 현재 셸 구현(statusline.sh 의 format_gh)에 각 레코드를 실제로 먹여 뽑았다.
func TestGitHubAccountStates(t *testing.T) {
	const now = int64(1_800_000_000)
	cases := []struct{ cache, want string }{
		{"octocat", "gh@personal"}, // 탭 없는 한 줄 = 계정명만
		{"v2\toctocat\tok\t0", "gh@personal"},
		{"v2\toctocat\tauth_failed\t0", "gh@personal!"},
		{"v2\toctocat\tunknown\t0", "gh@personal?"},
		{"v2\toctocat\tbogus_state\t0", "gh@personal?"}, // 모르는 상태는 unknown 으로 접는다
		{"v2\t-\tno_active\t0", "gh@---"},
		{"v2\t\tok\t0", "gh@?"},                // 연속 탭이 한 구분자로 접혀 필드 수가 어긋난다
		{"v9\toctocat\tok\t0", "gh@personal?"}, // 모르는 판 = unknown, 라벨 매핑은 그대로
		{"v1\toctocat\tok\t0", "gh@personal?"},
		{"", "gh@?"},
		{"v2\toctocat", "gh@?"},  // 필드 수가 어긋나면 계정 미상
		{"v2\t-\tok\t0", "gh@?"}, // 계정명 자리를 상태보다 먼저 가른다
		{"v2\t-\tunknown\t0", "gh@?"},
		{"v2\tnobody-xyz\tok\t0", "gh@nobody-xyz"}, // 미매핑 계정은 계정명 그대로
		{"v2\tbadcolor\tok\t0", "gh@weird"},
		{"v2\tescape\tok\t0", "gh@lbl"},
		{"v2\toctocat\tok\t0\textra", "gh@?"},
		{"v2\toctocat\tok\t0\textra\tmore", "gh@?"},
		{"\toctocat\tok\t0", "gh@?"}, // 선행 탭은 무시되어 필드가 하나 밀린다
		{"v2\ttestwork\trate_limited\t" + strconv.FormatInt(now+540, 10), "gh@work⏳9m"},
		{"v2\ttestwork\trate_limited\t" + strconv.FormatInt(now+30, 10), "gh@work⏳1m"},
		{"v2\ttestwork\trate_limited\t" + strconv.FormatInt(now-60, 10), "gh@work"},
		{"v2\ttestwork\trate_limited\tnotanumber", "gh@work"},
	}
	for _, c := range cases {
		cacheDir, configDir := ghFixture(t, c.cache)
		if got := plain(GitHubAccount(cacheDir, configDir, ghRoot, now)); got != c.want {
			t.Errorf("GitHubAccount(%q) = %q, want %q", c.cache, got, c.want)
		}
	}
}

func TestGitHubAccountColors(t *testing.T) {
	const now = int64(1_800_000_000)
	cases := []struct{ cache, wantPrefix string }{
		{"v2\toctocat\tok\t0", theme.Amber214 + "gh@personal"},
		{"v2\toctocat\tauth_failed\t0", theme.Red + "gh@personal!"},
		{"v2\toctocat\tunknown\t0", theme.Grey240 + "gh@personal?"},
		{"v2\t-\tno_active\t0", theme.Grey240 + "gh@---"},
		{"", theme.Grey240 + "gh@?"},
	}
	for _, c := range cases {
		cacheDir, configDir := ghFixture(t, c.cache)
		if got := GitHubAccount(cacheDir, configDir, ghRoot, now); !strings.HasPrefix(got, c.wantPrefix) {
			t.Errorf("GitHubAccount(%q) = %q, want prefix %q", c.cache, got, c.wantPrefix)
		}
	}
	// 라벨은 설정 색, 한도 마커만 노랑이다.
	cacheDir, configDir := ghFixture(t, "v2\ttestwork\trate_limited\t"+strconv.FormatInt(now+540, 10))
	want := "\033[38;5;27mgh@work" + theme.Reset + theme.Yellow + "⏳9m" + theme.Reset
	if got := GitHubAccount(cacheDir, configDir, ghRoot, now); got != want {
		t.Errorf("GitHubAccount rate_limited = %q, want %q", got, want)
	}
}

func TestGitHubAccountIsPerRepository(t *testing.T) {
	cacheDir, configDir := ghFixture(t, "v2\toctocat\tok\t0")
	other := filepath.Join(cacheDir, "%repo%other")
	if err := os.WriteFile(other, []byte("v2\ttestwork\tok\t0"), 0o600); err != nil {
		t.Fatal(err)
	}
	cases := []struct{ root, want string }{
		{ghRoot, "gh@personal"},
		{"/repo/other", "gh@work"},
		{"/repo/never-recorded", ""},
		{"", ""}, // 저장소가 아니면 캐시가 있어도 그리지 않는다
	}
	for _, c := range cases {
		if got := plain(GitHubAccount(cacheDir, configDir, c.root, 0)); got != c.want {
			t.Errorf("root=%q -> %q, want %q", c.root, got, c.want)
		}
	}
}

// The shell keys the cache by the physical root git reports, so a symlinked cwd must find it.
func TestGitHubAccountResolvesSymlinkedRoot(t *testing.T) {
	real := t.TempDir()
	link := filepath.Join(t.TempDir(), "link")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	physical, err := filepath.EvalSymlinks(real)
	if err != nil {
		t.Fatal(err)
	}
	cacheDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(cacheDir, strings.ReplaceAll(physical, "/", "%")),
		[]byte("v2\toctocat\tok\t0"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := plain(GitHubAccount(cacheDir, t.TempDir(), link, 0)); got != "gh@octocat" {
		t.Errorf("심볼릭 링크 경로 -> %q, want gh@octocat", got)
	}
}

func TestGitHubAccountRejectsNonNumericColor(t *testing.T) {
	// gh-accounts 의 색 코드가 숫자가 아니면 기본색을 쓴다. 설정 파일이 이스케이프를 주입하지 못하게 막는다.
	for _, login := range []string{"badcolor", "escape"} {
		cacheDir, configDir := ghFixture(t, "v2\t"+login+"\tok\t0")
		got := GitHubAccount(cacheDir, configDir, ghRoot, 0)
		if !strings.HasPrefix(got, theme.Amber214) {
			t.Errorf("%s: 기본색으로 폴백하지 않았다: %q", login, got)
		}
		if strings.Count(got, "\033") != 2 {
			t.Errorf("%s: 이스케이프가 주입됐다: %q", login, got)
		}
	}
}

func TestGitHubAccountMissingCacheRendersNothing(t *testing.T) {
	// 저장소의 캐시 파일 자체가 없으면 아무것도 내지 않는다(줄에서 자연히 빠진다).
	if got := GitHubAccount(t.TempDir(), t.TempDir(), ghRoot, 0); got != "" {
		t.Errorf("캐시 부재: %q", got)
	}
}

func ccFixture(t *testing.T, email string) (configDir, cacheDir string) {
	t.Helper()
	configDir, cacheDir = t.TempDir(), t.TempDir()
	if err := os.WriteFile(filepath.Join(configDir, ".claude.json"),
		[]byte(`{"oauthAccount":{"emailAddress":"`+email+`"}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	return configDir, cacheDir
}

func TestClaudeAccountReadsAndCachesTheEmail(t *testing.T) {
	configDir, cacheDir := ccFixture(t, "octocat@example.com")
	got := ClaudeAccount(configDir, cacheDir)
	if plain(got) != "octocat@example.com" {
		t.Fatalf("ClaudeAccount = %q", got)
	}
	if !strings.HasPrefix(got, theme.Coral173) {
		t.Errorf("coral(173) 색이 아니다: %q", got)
	}
	b, err := os.ReadFile(filepath.Join(cacheDir, "cc-account.env"))
	if err != nil || strings.TrimSpace(string(b)) != "email=octocat@example.com" {
		t.Errorf("캐시 파일 = %q (%v)", b, err)
	}
}

func TestClaudeAccountUsesCacheUntilConfigIsNewer(t *testing.T) {
	// .claude.json 이 캐시보다 새 것이 아니면 캐시된 이메일을 쓴다. 이 파일은 수백 KB 라 매 렌더 스캔하면 느리다.
	configDir, cacheDir := ccFixture(t, "octocat@example.com")
	ClaudeAccount(configDir, cacheDir)

	cf := filepath.Join(configDir, ".claude.json")
	// 내용만 바꾸고 mtime 을 캐시보다 과거로 되돌리면 캐시가 이겨야 한다.
	if err := os.WriteFile(cf, []byte(`{"oauthAccount":{"emailAddress":"changed@example.com"}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-time.Hour)
	if err := os.Chtimes(cf, old, old); err != nil {
		t.Fatal(err)
	}
	if got := plain(ClaudeAccount(configDir, cacheDir)); got != "octocat@example.com" {
		t.Errorf("캐시가 이겨야 한다: %q", got)
	}

	// 원본이 캐시보다 새 것이 되면 다시 스캔한다.
	future := time.Now().Add(time.Hour)
	if err := os.Chtimes(cf, future, future); err != nil {
		t.Fatal(err)
	}
	if got := plain(ClaudeAccount(configDir, cacheDir)); got != "changed@example.com" {
		t.Errorf("원본이 새 것이면 재스캔해야 한다: %q", got)
	}
}

func TestClaudeAccountNeverWritesConfig(t *testing.T) {
	// .claude.json 은 Claude Code 런타임 상태다. 읽기만 하는지 mtime 과 내용으로 확인한다.
	configDir, cacheDir := ccFixture(t, "octocat@example.com")
	cf := filepath.Join(configDir, ".claude.json")
	before, err := os.Stat(cf)
	if err != nil {
		t.Fatal(err)
	}
	wantBody, err := os.ReadFile(cf)
	if err != nil {
		t.Fatal(err)
	}
	ClaudeAccount(configDir, cacheDir)
	ClaudeAccount(configDir, cacheDir)
	after, err := os.Stat(cf)
	if err != nil {
		t.Fatal(err)
	}
	if !after.ModTime().Equal(before.ModTime()) || after.Size() != before.Size() {
		t.Errorf("설정 파일이 바뀌었다: %v -> %v", before.ModTime(), after.ModTime())
	}
	gotBody, err := os.ReadFile(cf)
	if err != nil || string(gotBody) != string(wantBody) {
		t.Errorf("설정 파일 내용이 바뀌었다")
	}
}

func TestClaudeAccountScansOnlyInsideTheOAuthBlock(t *testing.T) {
	// projects 키가 파일 경로라 이 파일은 통째로 파싱하지 않는다. oauthAccount 블록에
	// 들어간 뒤 첫 emailAddress 한 줄만 뽑으므로, 블록 앞의 다른 emailAddress 는 무시한다.
	configDir, cacheDir := t.TempDir(), t.TempDir()
	body := "{\n  \"projects\": {\"/a.b/c\": {\"emailAddress\": \"wrong@example.com\"}},\n" +
		"  \"oauthAccount\": {\n    \"emailAddress\": \"right@example.com\"\n  }\n}\n"
	if err := os.WriteFile(filepath.Join(configDir, ".claude.json"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := plain(ClaudeAccount(configDir, cacheDir)); got != "right@example.com" {
		t.Errorf("ClaudeAccount = %q, want right@example.com", got)
	}
}

func TestClaudeAccountMissingFileRendersNothing(t *testing.T) {
	if got := ClaudeAccount(t.TempDir(), t.TempDir()); got != "" {
		t.Errorf("설정 파일 부재: %q", got)
	}
}

// awsCacheFile writes an `aws login` cache entry whose idToken was issued at iat.
func awsCacheFile(t *testing.T, dir, name string, iat int64) string {
	t.Helper()
	return writeAWSCache(t, dir, name, awsIDToken(iat))
}

func writeAWSCache(t *testing.T, dir, name, idToken string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	body := `{"accessToken":{"accessKeyId":"x"},"idToken":"` + idToken + `"}`
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func awsIDToken(iat int64) string {
	enc := base64.RawURLEncoding.EncodeToString
	return enc([]byte(`{"alg":"none"}`)) + "." + enc([]byte(`{"iat":`+strconv.FormatInt(iat, 10)+`}`)) + ".sig"
}

// awsEnv is an AWS call fixture: a spawn that counts runs and a state file path.
type awsEnv struct {
	state   string
	spawns  int
	healthy bool // the second return value of the last AWS call
}

func newAWSEnv(t *testing.T) *awsEnv { return &awsEnv{state: filepath.Join(t.TempDir(), "aws-check")} }

func (e *awsEnv) spawn(string) { e.spawns++ }

func (e *awsEnv) render(dir string, now int64) string {
	text, healthy := AWS(dir, e.state, now, e.spawn)
	e.healthy = healthy
	return plain(text)
}

func TestAWSNoCacheRendersEmpty(t *testing.T) {
	e := newAWSEnv(t)
	if got := e.render(filepath.Join(t.TempDir(), "missing"), 0); got != "" {
		t.Errorf("캐시 디렉터리 부재: %q", got)
	}
	if got := e.render(t.TempDir(), 0); got != "" {
		t.Errorf("캐시 파일 부재: %q", got)
	}
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "notes.txt"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := e.render(dir, 0); got != "" {
		t.Errorf("json 아닌 파일만 있으면 빈 문자열: %q", got)
	}
	if e.spawns != 0 {
		t.Errorf("캐시가 없으면 확인하지 않는다: spawns=%d", e.spawns)
	}
}

// A recent iat proves the login is live, so no check runs.
func TestAWSFreshCredentialsNeedNoCheck(t *testing.T) {
	e := newAWSEnv(t)
	dir := t.TempDir()
	now := time.Now().Unix()
	awsCacheFile(t, dir, "session.json", now-14*60)
	if got := e.render(dir, now); got != "aws:✓" || e.spawns != 0 {
		t.Errorf("got %q spawns=%d, want aws:✓ 0", got, e.spawns)
	}
}

// An old iat means no refresh happened, not that the login ended: the last check decides.
func TestAWSStaleCredentialsFollowLastCheck(t *testing.T) {
	now := time.Now().Unix()
	cases := []struct {
		name   string
		state  string // "" = no state file
		want   string
		spawns int
	}{
		{"확인 기록 없음", "", "aws:?", 1},
		{"최근 ok", "%d ok", "aws:✓", 0},
		{"최근 fail", "%d fail", "aws:expired", 0},
		{"오래된 ok", "%d ok", "aws:✓", 1},
		{"오래된 fail", "%d fail", "aws:expired", 1},
		{"깨진 기록", "garbage", "aws:?", 1},
	}
	ages := map[string]int64{"최근 ok": 60, "최근 fail": 60, "오래된 ok": 11 * 60, "오래된 fail": 11 * 60}
	for _, c := range cases {
		e := newAWSEnv(t)
		dir := t.TempDir()
		awsCacheFile(t, dir, "session.json", now-13*3600)
		if c.state != "" {
			body := c.state
			if strings.Contains(body, "%d") {
				body = fmt.Sprintf(body, now-ages[c.name])
			}
			if err := os.WriteFile(e.state, []byte(body+"\n"), 0o600); err != nil {
				t.Fatal(err)
			}
		}
		if got := e.render(dir, now); got != c.want || e.spawns != c.spawns {
			t.Errorf("%s: got %q spawns=%d, want %q %d", c.name, got, e.spawns, c.want, c.spawns)
		}
	}
}

// Only aws:✓ is healthy; the narrow layout hides that one and shows every other state,
// including an empty cache, which has no text to show.
func TestAWSHealthyOnlyForTheCheckMark(t *testing.T) {
	now := time.Now().Unix()
	cases := []struct {
		name    string
		iat     int64  // 0 = no cache file
		state   string // "%d ok" style, "" = no state file
		want    string
		healthy bool
	}{
		{"캐시 없음", 0, "", "", false},
		{"방금 로그인", now - 60, "", "aws:✓", true},
		{"오래된 로그인 + 최근 ok", now - 13*3600, "%d ok", "aws:✓", true},
		{"오래된 로그인 + 최근 fail", now - 13*3600, "%d fail", "aws:expired", false},
		{"오래된 로그인 + 기록 없음", now - 13*3600, "", "aws:?", false},
	}
	for _, c := range cases {
		e := newAWSEnv(t)
		dir := t.TempDir()
		if c.iat != 0 {
			awsCacheFile(t, dir, "session.json", c.iat)
		}
		if c.state != "" {
			if err := os.WriteFile(e.state, []byte(fmt.Sprintf(c.state, now-60)+"\n"), 0o600); err != nil {
				t.Fatal(err)
			}
		}
		if got := e.render(dir, now); got != c.want || e.healthy != c.healthy {
			t.Errorf("%s: got %q healthy=%v, want %q %v", c.name, got, e.healthy, c.want, c.healthy)
		}
	}
	e := newAWSEnv(t)
	dir := t.TempDir()
	writeAWSCache(t, dir, "session.json", "notajwt")
	if got := e.render(dir, now); got != "aws:?" || e.healthy {
		t.Errorf("판독 불가: got %q healthy=%v, want aws:? false", got, e.healthy)
	}
}

// Rendering again right after a spawn must not spawn a second check.
func TestAWSSpawnsOncePerTTL(t *testing.T) {
	e := newAWSEnv(t)
	dir := t.TempDir()
	now := time.Now().Unix()
	awsCacheFile(t, dir, "session.json", now-13*3600)
	e.render(dir, now)
	e.render(dir, now+5)
	if e.spawns != 1 {
		t.Errorf("spawns=%d, want 1", e.spawns)
	}
	e.render(dir, now+awsCheckTTL)
	if e.spawns != 2 {
		t.Errorf("TTL 경과 후 spawns=%d, want 2", e.spawns)
	}
}

func TestAWSUnreadableLoginTimeRendersQuestionMark(t *testing.T) {
	enc := base64.RawURLEncoding.EncodeToString
	claims := func(json string) string { return "h." + enc([]byte(json)) + ".s" }
	cases := map[string]string{
		"idToken 없음":          "",
		"세 조각이 아님":            "notajwt",
		"payload 가 base64 아님": "h.!!!.s",
		"payload 가 JSON 아님":   claims("not json"),
		"iat 없음":              claims(`{"exp":1}`),
		"iat 가 숫자가 아님":        claims(`{"iat":"abc"}`),
		"iat 가 0":             claims(`{"iat":0}`),
	}
	for name, token := range cases {
		e := newAWSEnv(t)
		dir := t.TempDir()
		writeAWSCache(t, dir, "session.json", token)
		if got := e.render(dir, time.Now().Unix()); got != "aws:?" || e.spawns != 0 {
			t.Errorf("%s -> %q spawns=%d, want aws:? 0", name, got, e.spawns)
		}
	}
}

func TestAWSBrokenCacheFileRendersQuestionMark(t *testing.T) {
	e := newAWSEnv(t)
	dir := t.TempDir()
	link := filepath.Join(dir, "broken.json")
	if err := os.Symlink(filepath.Join(dir, "does-not-exist"), link); err != nil {
		t.Fatal(err)
	}
	if got := e.render(dir, time.Now().Unix()); got != "aws:?" {
		t.Errorf("캐시 파일 판독 불가 → aws:? — got %q", got)
	}
}

func TestAWSNewestCacheFileByMtime(t *testing.T) {
	dir := t.TempDir()
	older := awsCacheFile(t, dir, "older.json", 0)
	newer := awsCacheFile(t, dir, "newer.json", 0)
	past := time.Now().Add(-time.Hour)
	if err := os.Chtimes(older, past, past); err != nil {
		t.Fatal(err)
	}
	got, ok := newestCacheFile(dir)
	if !ok || got != newer {
		t.Errorf("newestCacheFile = %q, %v; want %q, true", got, ok, newer)
	}
}

// The check script records ok/fail from the aws exit status and picks the profile
// that has a login_session.
func TestAWSCheckScript(t *testing.T) {
	for _, c := range []struct{ exit, want string }{{"0", "ok"}, {"255", "fail"}} {
		home := t.TempDir()
		bin := t.TempDir()
		cfg := "[default]\nregion = x\n[profile work]\nlogin_session = arn:example\n"
		if err := os.WriteFile(filepath.Join(home, "config"), []byte(cfg), 0o600); err != nil {
			t.Fatal(err)
		}
		fake := "#!/bin/sh\necho \"$@\" > '" + filepath.Join(home, "args") + "'\nexit " + c.exit + "\n"
		if err := os.WriteFile(filepath.Join(bin, "aws"), []byte(fake), 0o755); err != nil {
			t.Fatal(err)
		}
		state := filepath.Join(home, "aws-check")
		cmd := exec.Command("sh", "-c", awsCheckScript, "sh", state)
		cmd.Env = []string{"PATH=" + bin + ":/usr/bin:/bin", "AWS_CONFIG_FILE=" + filepath.Join(home, "config")}
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("%v: %s", err, out)
		}
		_, got := readAWSCheck(state)
		args, _ := os.ReadFile(filepath.Join(home, "args"))
		if got != c.want || strings.TrimSpace(string(args)) != "--profile work sts get-caller-identity" {
			t.Errorf("exit %s: result=%q args=%q", c.exit, got, args)
		}
	}
}
