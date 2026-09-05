package segments

import (
	"os"
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

// ghFixture writes the prompt cache and the label mapping the segment reads.
func ghFixture(t *testing.T, cache string) (dataDir, configDir string) {
	t.Helper()
	dataDir, configDir = t.TempDir(), t.TempDir()
	if err := os.WriteFile(filepath.Join(dataDir, "gh-prompt-user"), []byte(cache), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(configDir, "claude-statusline"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(configDir, "claude-statusline", "gh-accounts"),
		[]byte("# comment\noctocat=personal,214\ntestwork=work,27\nbadcolor=weird,zz\nescape=lbl,1m\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return dataDir, configDir
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
		dataDir, configDir := ghFixture(t, c.cache)
		if got := plain(GitHubAccount(dataDir, configDir, now)); got != c.want {
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
		dataDir, configDir := ghFixture(t, c.cache)
		if got := GitHubAccount(dataDir, configDir, now); !strings.HasPrefix(got, c.wantPrefix) {
			t.Errorf("GitHubAccount(%q) = %q, want prefix %q", c.cache, got, c.wantPrefix)
		}
	}
	// 라벨은 설정 색, 한도 마커만 노랑이다.
	dataDir, configDir := ghFixture(t, "v2\ttestwork\trate_limited\t"+strconv.FormatInt(now+540, 10))
	want := "\033[38;5;27mgh@work" + theme.Reset + theme.Yellow + "⏳9m" + theme.Reset
	if got := GitHubAccount(dataDir, configDir, now); got != want {
		t.Errorf("GitHubAccount rate_limited = %q, want %q", got, want)
	}
}

func TestGitHubAccountRejectsNonNumericColor(t *testing.T) {
	// gh-accounts 의 색 코드가 숫자가 아니면 기본색을 쓴다. 설정 파일이 이스케이프를 주입하지 못하게 막는다.
	for _, login := range []string{"badcolor", "escape"} {
		dataDir, configDir := ghFixture(t, "v2\t"+login+"\tok\t0")
		got := GitHubAccount(dataDir, configDir, 0)
		if !strings.HasPrefix(got, theme.Amber214) {
			t.Errorf("%s: 기본색으로 폴백하지 않았다: %q", login, got)
		}
		if strings.Count(got, "\033") != 2 {
			t.Errorf("%s: 이스케이프가 주입됐다: %q", login, got)
		}
	}
}

func TestGitHubAccountMissingCacheRendersNothing(t *testing.T) {
	// 캐시 파일 자체가 없으면 셸은 아무것도 내지 않는다(줄에서 자연히 빠진다).
	if got := GitHubAccount(t.TempDir(), t.TempDir(), 0); got != "" {
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

func awsCreds(t *testing.T, exp string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "credentials")
	if err := os.WriteFile(p, []byte("[default]\nx_security_token_expires = "+exp+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func stubSaml2aws(t *testing.T) {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "saml2aws"), []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
}

func TestAWSRendersNothingWithoutSaml2aws(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	t.Setenv("AWS_SESSION_EXPIRATION", "2099-01-01T00:00:00+00:00")
	if got := AWS(awsCreds(t, "2099-01-01T00:00:00+00:00"), t.TempDir(), t.TempDir(), 0); got != "" {
		t.Errorf("saml2aws 미설치: %q", got)
	}
}

func TestAWSThresholds(t *testing.T) {
	stubSaml2aws(t)
	base := time.Date(2026, 8, 20, 12, 0, 0, 0, time.UTC)
	now := base.Unix()
	cases := []struct {
		offset time.Duration
		want   string
	}{
		{30 * time.Minute, "aws:✓"},
		{11 * time.Minute, "aws:✓"},
		{10 * time.Minute, "aws:⏳10m"},
		{5 * time.Minute, "aws:⏳5m"},
		{1 * time.Minute, "aws:⏳1m"},
		{0, "aws:expired"},
		{-time.Hour, "aws:expired"},
	}
	for _, c := range cases {
		exp := base.Add(c.offset).Format("2006-01-02T15:04:05-07:00")
		t.Setenv("AWS_SESSION_EXPIRATION", exp)
		if got := plain(AWS("", t.TempDir(), t.TempDir(), now)); got != c.want {
			t.Errorf("offset=%v exp=%s -> %q, want %q", c.offset, exp, got, c.want)
		}
	}
}

func TestAWSUnknownExpirationRendersQuestionMark(t *testing.T) {
	stubSaml2aws(t)
	t.Setenv("AWS_SESSION_EXPIRATION", "")
	if got := plain(AWS(filepath.Join(t.TempDir(), "gone"), t.TempDir(), t.TempDir(), 0)); got != "aws:?" {
		t.Errorf("만료를 못 찾으면 aws:? — got %q", got)
	}
}

func TestAWSCachesOnlyTheFileParsedEpoch(t *testing.T) {
	// env 로 만료가 주어졌으면 파일도 캐시도 건드리지 않는다. 파일에서 읽은 경우에만 캐시한다.
	stubSaml2aws(t)
	base := time.Date(2026, 8, 20, 12, 0, 0, 0, time.UTC)
	exp := base.Add(2 * time.Hour)
	cacheDir := t.TempDir()

	t.Setenv("AWS_SESSION_EXPIRATION", exp.Format("2006-01-02T15:04:05-07:00"))
	AWS(awsCreds(t, exp.Format("2006-01-02T15:04:05-07:00")), t.TempDir(), cacheDir, base.Unix())
	if _, err := os.Stat(filepath.Join(cacheDir, "aws-exp.env")); !os.IsNotExist(err) {
		t.Error("env 경로에서는 캐시하지 않는다")
	}

	t.Setenv("AWS_SESSION_EXPIRATION", "")
	creds := awsCreds(t, exp.Format("2006-01-02T15:04:05-07:00"))
	if got := plain(AWS(creds, t.TempDir(), cacheDir, base.Unix())); got != "aws:✓" {
		t.Fatalf("파일 경로 렌더 = %q", got)
	}
	b, err := os.ReadFile(filepath.Join(cacheDir, "aws-exp.env"))
	if err != nil {
		t.Fatal(err)
	}
	if want := "exp_epoch=" + strconv.FormatInt(exp.Unix(), 10); strings.TrimSpace(string(b)) != want {
		t.Errorf("캐시 = %q, want %q", b, want)
	}
}

func TestAWSExpiredSuppressionShowsDash(t *testing.T) {
	stubSaml2aws(t)
	dataDir := t.TempDir()
	today := time.Now().Format("2006-01-02")
	if err := os.WriteFile(filepath.Join(dataDir, "saml2aws-login-suppress"),
		[]byte("value="+today+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AWS_SESSION_EXPIRATION", "2020-01-01T00:00:00+00:00")
	if got := plain(AWS("", dataDir, t.TempDir(), time.Now().Unix())); got != "aws:-" {
		t.Errorf("억제 파일이 오늘이면 aws:- — got %q", got)
	}
	if err := os.WriteFile(filepath.Join(dataDir, "saml2aws-login-suppress"),
		[]byte("value=1999-01-01\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := plain(AWS("", dataDir, t.TempDir(), time.Now().Unix())); got != "aws:expired" {
		t.Errorf("억제 날짜가 오늘이 아니면 aws:expired — got %q", got)
	}
}

func TestAWSExpiredSuppressionUsesRenderTime(t *testing.T) {
	stubSaml2aws(t)
	dataDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dataDir, "saml2aws-login-suppress"),
		[]byte("value=2026-08-20\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AWS_SESSION_EXPIRATION", "2020-01-01T00:00:00+00:00")
	if got := plain(AWS("", dataDir, t.TempDir(), time.Date(2026, 8, 20, 0, 0, 0, 0, time.Local).Unix())); got != "aws:-" {
		t.Fatalf("render 시각의 억제를 써야 한다: %q", got)
	}
	if got := plain(AWS("", dataDir, t.TempDir(), time.Date(2026, 8, 21, 0, 0, 0, 0, time.Local).Unix())); got != "aws:expired" {
		t.Fatalf("다른 render 날짜에는 억제하지 않아야 한다: %q", got)
	}
}
