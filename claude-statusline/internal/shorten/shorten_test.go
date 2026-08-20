package shorten

import (
	"os"
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

// 이 표는 어느 낱말이 남고 어디가 ↪N 으로 접히는지만 본다. 색은 TestPathKeepsColoredOutput 이 본다.
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

// 티켓 판정은 프로젝트 키가 전부 대문자일 때만 참이다. lower-1-x-y-z 줄이 그 규칙을 고정한다.
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
		// 소문자 프로젝트 키는 티켓이 아니므로 낱말 접기의 대상이다.
		{"lower-1-x-y-z", "lower-1-↪1-y-z"},
		{"test-1-foo-bar", "test-↪2-bar"},
	}
	for _, c := range cases {
		if got := Branch(c.in); got != c.want {
			t.Errorf("Branch(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// 색까지 포함한 출력을 고정한다. 위의 plain 표는 어느 낱말이 남는지만 보고 색은 보지 않아,
// 저장소명과 현재 폴더에 파랑을 주는 규칙이 무너져도 통과한다. 여기 적힌 값은 셸 구현이
// 오라클로 남아 있던 마지막 시점에 그 구현과 바이트 단위로 같음을 확인하고 옮긴 것이다.
func TestPathKeepsColoredOutput(t *testing.T) {
	home := tree(t)
	j := func(rel string) string { return filepath.Join(home, rel) }
	cases := []struct{ in, want string }{
		{home, "\x1b[2m~\x1b[0m"},
		{j("repos/a/b/c/d/e/f/g"), "\x1b[2m~\x1b[0m\x1b[2m/\x1b[0m\x1b[2m↪7\x1b[0m\x1b[2m/\x1b[0m\x1b[34mg\x1b[0m"},
		{j("repos/proj"), "\x1b[2m~/repos/proj\x1b[0m"},
		{j("repos/proj/sub/deep"), "\x1b[2m~\x1b[0m\x1b[2m/\x1b[0m\x1b[2m↪1\x1b[0m\x1b[2m/\x1b[0m\x1b[34mproj\x1b[0m\x1b[2m/\x1b[0m\x1b[2m↪1\x1b[0m\x1b[2m/\x1b[0m\x1b[34mdeep\x1b[0m"},
		{j("collide/foo/sub/foo/bar"), "\x1b[2m~\x1b[0m\x1b[2m/\x1b[0m\x1b[2m↪1\x1b[0m\x1b[2m/\x1b[0m\x1b[34mfoo\x1b[0m\x1b[2m/\x1b[0m\x1b[2m↪2\x1b[0m\x1b[2m/\x1b[0m\x1b[34mbar\x1b[0m"},
		{j("nested/outer/mid/inner/x"), "\x1b[2m~\x1b[0m\x1b[2m/\x1b[0m\x1b[2m↪1\x1b[0m\x1b[2m/\x1b[0m\x1b[34mouter\x1b[0m\x1b[2m/\x1b[0m\x1b[2m↪1\x1b[0m\x1b[2m/\x1b[0m\x1b[34minner\x1b[0m\x1b[2m/\x1b[0m\x1b[34mx\x1b[0m"},
		{j("repos/a/b"), "\x1b[2m~\x1b[0m\x1b[2m/\x1b[0m\x1b[2m↪2\x1b[0m\x1b[2m/\x1b[0m\x1b[34mb\x1b[0m"},
		{"/tmp", "\x1b[2m/tmp\x1b[0m"},
		{"/usr/local/share", "\x1b[2m/\x1b[0m\x1b[2musr\x1b[0m\x1b[2m/\x1b[0m\x1b[2m↪1\x1b[0m\x1b[2m/\x1b[0m\x1b[34mshare\x1b[0m"},
		{"/", "\x1b[2m/\x1b[0m"},
		{"aaa/bbb/ccc/ddd/eee", "\x1b[2maaa\x1b[0m\x1b[2m/\x1b[0m\x1b[2m↪3\x1b[0m\x1b[2m/\x1b[0m\x1b[34meee\x1b[0m"},
	}
	for _, c := range cases {
		if got := Path(c.in, home); got != c.want {
			t.Errorf("Path(%q)\n got %q\nwant %q", c.in, got, c.want)
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
