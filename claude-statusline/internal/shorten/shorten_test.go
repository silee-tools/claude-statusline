package shorten

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

var ansiRe = regexp.MustCompile(`\x1b\[[0-9;]*m`)

func plain(s string) string { return ansiRe.ReplaceAllString(s, "") }

// tree builds the directory shapes the path rules branch on: a repo at the top of
// a chain, a non-repo directory that shares a repo's name, nested repos, and a deep
// chain with no repo at all. It returns the HOME of that tree.
func tree(t *testing.T) string {
	t.Helper()
	home := filepath.Join(t.TempDir(), "home")
	for _, d := range []string{
		"repos/a/b/c/d/e/f/g",
		"repos/proj/.git",
		"repos/proj/sub/deep",
		"collide/foo/.git",
		"collide/foo/sub/foo/bar",
		"nested/outer/.git",
		"nested/outer/mid/inner/.git",
		"nested/outer/mid/inner/x",
	} {
		if err := os.MkdirAll(filepath.Join(home, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return home
}

// 기대값은 scripts/shorten.sh --plain path 를 위 트리에 실제로 돌려 뽑았다.
func TestPathMatchesShellImplementation(t *testing.T) {
	home := tree(t)
	cases := []struct{ in, home, want string }{
		{home, home, "~"},
		{filepath.Join(home, "repos/a/b/c/d/e/f/g"), home, "~/↪7/g"},
		{"/tmp", home, "/tmp"},
		{"/usr/local/share", home, "/usr/↪1/share"},
		{filepath.Join(home, "repos/proj"), home, "~/repos/proj"},
		{filepath.Join(home, "repos/proj/sub/deep"), home, "~/↪1/proj/↪1/deep"},
		{filepath.Join(home, "collide/foo/sub/foo/bar"), home, "~/↪1/foo/↪2/bar"},
		{filepath.Join(home, "nested/outer/mid/inner/x"), home, "~/↪1/outer/↪1/inner/x"},
		{filepath.Join(home, "repos"), home, "~/repos"},
		{filepath.Join(home, "repos/a"), home, "~/repos/a"},
		{filepath.Join(home, "repos/a/b"), home, "~/↪2/b"},
		{"aaa/bbb/ccc/ddd/eee", home, "aaa/↪3/eee"},
		{"/", home, "/"},
		// HOME 경계는 문자열 접두사가 아니라 경로 구성요소로 판정한다.
		{"/opt/a", "/opt/a", "~"},
		{"/opt/a/project", "/opt/a", "~/project"},
		{"/opt/abc/project", "/opt/a", "/opt/↪1/project"},
		{"/opt/a/project", "/opt/a/", "~/project"},
		// 루트 HOME 은 모든 경로를 ~ 아래로 넣지 않고 절대경로로 남긴다.
		{"/", "/", "/"},
		{"/child", "/", "/child"},
		{"/opt/a/project", "/", "/opt/↪1/project"},
		{"/child", "////", "/child"},
		{"/opt/a/project", "////", "/opt/↪1/project"},
	}
	for _, c := range cases {
		if got := plain(Path(c.in, c.home)); got != c.want {
			t.Errorf("Path(%q, %q) = %q, want %q", c.in, c.home, got, c.want)
		}
	}
}

// 기대값은 scripts/shorten.sh --plain branch 를 실제로 돌려 뽑았다. 티켓 판정은
// LC_ALL=C 기준이다 — 근거는 TestBranchMatchesShellUnderCLocale 에 있다.
func TestBranchMatchesShellImplementation(t *testing.T) {
	cases := []struct{ in, want string }{
		{"main", "main"},
		{"wip", "wip"},
		{"feature/CND-1234-some-long-branch-name-here", "feature/CND-1234-some-long-↪1-name-here"},
		{"release/2026-08", "release/2026-08"},
		{"feature/one-two-three-four", "feature/one-↪2-four"},
		{"one-two-three-four", "one-↪2-four"},
		{"one-two-three-four-five", "one-two-↪1-four-five"},
		{"PROJ-9-a-b-c-d-e", "PROJ-9-a-b-↪1-d-e"},
		{"hotfix/x", "hotfix/x"},
		{"bugfix/AB-1-c", "bugfix/AB-1-c"},
		{"change/y", "change/y"},
		{"a-b-c", "a-b-c"},
		{"a-b-c-d", "a-↪2-d"},
		{"a-b-c-d-e", "a-b-↪1-d-e"},
		{"a-b-c-d-e-f", "a-b-↪2-e-f"},
		{"PROJ-12-only", "PROJ-12-only"},
		{"PROJ--1-x", "PROJ-↪2-x"},
		{"feature/PROJ-1469-connect-api-secrets", "feature/PROJ-1469-connect-api-secrets"},
		{"한글브랜치이름아주길게테스트용문자열모음입니다", "한글브랜치이름아주길게테스트용문자열모음입니다"},
		{"", ""},
		{"-", "-"},
		{"a--b", "a--b"},
		// 선행 구분자는 빈 낱말 하나를 만들고 후행 구분자는 만들지 않는다.
		{"-a-b-c", "-↪2-c"},
		{"a-b-c-", "a-b-c-"},
		{"-a-b-c-", "-↪2-c"},
		// 소문자 프로젝트 키는 티켓이 아니다. 이 줄이 LC_ALL=C 기준을 고정한다.
		{"lower-1-x-y-z", "lower-1-↪1-y-z"},
		{"test-1-foo-bar", "test-↪2-bar"},
	}
	for _, c := range cases {
		if got := Branch(c.in); got != c.want {
			t.Errorf("Branch(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// shellOut runs the shell implementation as the oracle. LC_ALL=C 로 부르는 이유는
// 기본 로케일에서 case 의 [A-Z] 범위가 콜레이션을 타 b..z 까지 대문자로 취급하기
// 때문이다. 그 상태의 셸은 lower-1-x-y-z 를 티켓으로 읽어 축약하지 않는데, 같은
// 파일의 주석이 적은 규칙("대문자로만 이뤄지지 않으면 티켓 아님")과 어긋난다.
func shellOut(t *testing.T, home string, args ...string) (string, bool) {
	t.Helper()
	script := filepath.Join("..", "..", "scripts", "shorten.sh")
	if _, err := os.Stat(script); err != nil {
		return "", false
	}
	cmd := exec.Command("sh", append([]string{script}, args...)...)
	cmd.Env = append(os.Environ(), "HOME="+home, "LC_ALL=C")
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("sh %s %v: %v", script, args, err)
	}
	return strings.TrimRight(string(out), "\n"), true
}

// 표 기대값을 손으로 옮기다 생기는 오차를 막는 차동 테스트다. 셸 구현이 저장소에
// 남아 있는 동안 이 테스트가 Go 와 셸을 매 실행 대조한다.
func TestPathAgreesWithShellByteForByte(t *testing.T) {
	home := tree(t)
	for _, p := range []string{
		home,
		filepath.Join(home, "repos/a/b/c/d/e/f/g"),
		filepath.Join(home, "repos/proj"),
		filepath.Join(home, "repos/proj/sub/deep"),
		filepath.Join(home, "collide/foo/sub/foo/bar"),
		filepath.Join(home, "nested/outer/mid/inner/x"),
		filepath.Join(home, "repos/a/b"),
		"/tmp", "/usr/local/share", "/", "aaa/bbb/ccc/ddd/eee",
	} {
		want, ok := shellOut(t, home, "--ansi", "path", p)
		if !ok {
			t.Skip("scripts/shorten.sh 부재 — 차동 대조 생략")
		}
		if got := Path(p, home); got != want {
			t.Errorf("Path(%q)\n got %q\nwant %q", p, got, want)
		}
	}
}

func TestBranchAgreesWithShellByteForByte(t *testing.T) {
	for _, b := range []string{
		"main", "wip", "feature/CND-1234-some-long-branch-name-here", "release/2026-08",
		"one-two-three-four", "one-two-three-four-five", "PROJ-9-a-b-c-d-e",
		"a-b-c-d", "PROJ--1-x", "-a-b-c", "a-b-c-", "lower-1-x-y-z", "test-1-foo-bar",
		"한글브랜치이름아주길게테스트용문자열모음입니다",
	} {
		want, ok := shellOut(t, "/nonexistent-home", "--plain", "branch", b)
		if !ok {
			t.Skip("scripts/shorten.sh 부재 — 차동 대조 생략")
		}
		if got := Branch(b); got != want {
			t.Errorf("Branch(%q) = %q, want %q", b, got, want)
		}
	}
}

func TestPathColorsRepoAndCurrentSegments(t *testing.T) {
	// 저장소명과 현재 폴더는 파랑, 나머지와 구분자는 dim 이다. 이 색을 떨어뜨리면
	// 첫 행의 표시가 이식 전과 달라진다.
	home := tree(t)
	got := Path(filepath.Join(home, "repos/proj/sub/deep"), home)
	if !strings.Contains(got, "\033[34mproj\033[0m") {
		t.Errorf("저장소명이 파랑이 아니다: %q", got)
	}
	if !strings.Contains(got, "\033[34mdeep\033[0m") {
		t.Errorf("현재 폴더가 파랑이 아니다: %q", got)
	}
	if !strings.Contains(got, "\033[2m↪1\033[0m") {
		t.Errorf("생략 표시가 dim 이 아니다: %q", got)
	}
}

func TestPathStripsControlCharacters(t *testing.T) {
	if got := plain(Path("/tmp\x1b[31m", "/nonexistent")); strings.ContainsRune(got, 0x1b) {
		t.Errorf("제어문자가 남았다: %q", got)
	}
}
