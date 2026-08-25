package gitinfo

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// newRepo 는 알려진 브랜치를 가진 저장소를 임시 디렉터리에 만든다.
// git 이 없거나 초기화가 실패하면 그 테스트만 건너뛴다 — 스위트 전체를 죽이지 않는다.
func newRepo(t *testing.T, branch string) string {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git 미설치")
	}
	dir := t.TempDir()
	run := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Skipf("git %v: %v (%s)", args, err, out)
		}
	}
	run("init", "-q")
	run("symbolic-ref", "HEAD", "refs/heads/"+branch)
	run("-c", "commit.gpgsign=false", "-c", "user.email=t@example.com", "-c", "user.name=t",
		"commit", "-q", "--allow-empty", "-m", "init")
	return dir
}

func TestBranchReadsCurrentBranch(t *testing.T) {
	dir := newRepo(t, "wip")
	if got := Branch(dir, t.TempDir()); got != "wip" {
		t.Fatalf("Branch = %q, want wip", got)
	}
}

func TestBranchServesFromCacheOnSecondCall(t *testing.T) {
	dir, cache := newRepo(t, "wip"), t.TempDir()
	Branch(dir, cache)
	if _, err := os.Stat(filepath.Join(cache, "git-branch.env")); err != nil {
		t.Fatalf("첫 호출이 캐시를 남기지 않았다: %v", err)
	}
	if got := Branch(dir, cache); got != "wip" {
		t.Fatalf("캐시 적중에서 Branch = %q, want wip", got)
	}
}

func TestBranchInvalidatesOnHeadContentChange(t *testing.T) {
	// 같은 초 안에 일어난 전환도 잡아야 한다. 그래서 무효화 판정을 mtime 이 아니라 HEAD 첫 줄 내용으로 한다.
	dir, cache := newRepo(t, "wip"), t.TempDir()
	if got := Branch(dir, cache); got != "wip" {
		t.Fatalf("사전 준비 실패: %q", got)
	}
	cmd := exec.Command("git", "checkout", "-q", "-b", "other")
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Skipf("브랜치 전환 실패: %v (%s)", err, out)
	}
	if got := Branch(dir, cache); got != "other" {
		t.Fatalf("전환을 놓쳤다: Branch = %q, want other", got)
	}
}

func TestUnbornBranchYieldsEmptyBranchAndStillCaches(t *testing.T) {
	// 커밋이 없는 브랜치에서 git 은 종료코드 128 로 죽으면서도 HEAD 경로와 리터럴 "HEAD" 를
	// 찍는다. 셸은 그 stdout 을 그대로 쓰므로 브랜치가 비고 캐시는 남는다. 종료코드를 보고
	// stdout 을 버리면 이 저장소에서 캐시가 만들어지지 않아 렌더마다 git 을 다시 부른다.
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git 미설치")
	}
	dir, cache := t.TempDir(), t.TempDir()
	cmd := exec.Command("git", "init", "-q")
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Skipf("git init: %v (%s)", err, out)
	}
	if got := Branch(dir, cache); got != "" {
		t.Errorf("커밋 없는 브랜치는 표시하지 않는다: %q", got)
	}
	if _, err := os.Stat(filepath.Join(cache, "git-branch.env")); err != nil {
		t.Errorf("HEAD 를 찾았으면 캐시를 남긴다: %v", err)
	}
}

func TestDetachedHeadYieldsEmptyBranch(t *testing.T) {
	dir := newRepo(t, "wip")
	cmd := exec.Command("git", "checkout", "-q", "--detach")
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Skipf("detach 실패: %v (%s)", err, out)
	}
	if got := Branch(dir, t.TempDir()); got != "" {
		t.Fatalf("detached HEAD 는 브랜치가 없다: %q", got)
	}
}

func TestBranchWorksFromASubdirectory(t *testing.T) {
	// 하위 디렉터리에는 .git 이 없다. .git/HEAD 직접 읽기로 바꾸면 여기서 브랜치가 사라진다.
	dir := newRepo(t, "wip")
	sub := filepath.Join(dir, "a", "b")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	if got := Branch(sub, t.TempDir()); got != "wip" {
		t.Fatalf("하위 디렉터리에서 Branch = %q, want wip", got)
	}
}

func TestBranchWorksInALinkedWorktree(t *testing.T) {
	// 연결된 worktree 의 .git 은 디렉터리가 아니라 gitdir: 포인터를 담은 파일이다.
	dir := newRepo(t, "main")
	wt := filepath.Join(t.TempDir(), "feat")
	cmd := exec.Command("git", "worktree", "add", "-q", wt, "-b", "feat")
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Skipf("worktree 생성 실패: %v (%s)", err, out)
	}
	if fi, err := os.Stat(filepath.Join(wt, ".git")); err != nil || fi.IsDir() {
		t.Skip("worktree 의 .git 이 파일이 아니다 — 이 git 판에서는 검증 대상이 아니다")
	}
	if got := Branch(wt, t.TempDir()); got != "feat" {
		t.Fatalf("worktree 에서 Branch = %q, want feat", got)
	}
}

func TestNonRepositoryYieldsEmptyBranchAndLeavesTheCacheAlone(t *testing.T) {
	// 캐시 항목은 현재 작업 디렉터리로 키가 걸려 있어 다른 디렉터리의 항목이 답으로 쓰이지
	// 않는다. 그래서 저장소가 아닌 곳을 지날 때 지우지 않고 남기며, 그 저장소로 돌아오면
	// 캐시가 그대로 적중해 git 을 다시 부르지 않는다.
	cache := t.TempDir()
	other := filepath.Join(cache, "git-branch.env")
	if err := os.WriteFile(other, []byte("cwd=/nope\nhead=/nope/HEAD\ntoken=x\nbranch=ghost\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := Branch(t.TempDir(), cache); got != "" {
		t.Fatalf("저장소가 아니면 브랜치가 없다: %q", got)
	}
	if _, err := os.Stat(other); err != nil {
		t.Fatalf("다른 디렉터리의 캐시 항목은 남긴다: %v", err)
	}
}

func TestBranchSkipsGitOutsideARepository(t *testing.T) {
	// 저장소가 아닌 곳에서는 캐시가 적중할 일이 없어 렌더마다 git 이 새로 떴다. 상위 경로 어디에도
	// .git 이 없다는 것은 git 자신이 걷는 조건이고 stat 몇 번으로 답이 나오므로, 프로세스를
	// 띄우지 않고 그 자리에서 판정한다.
	repo := newRepo(t, "wip")
	plain := t.TempDir()
	tally := blockGit(t)

	if got := Branch(plain, t.TempDir()); got != "" {
		t.Errorf("저장소가 아니면 브랜치가 없다: %q", got)
	}
	if n := tally(); n != 0 {
		t.Errorf("저장소가 아닌데 git 을 %d회 불렀다", n)
	}

	// 대조군이다. 이 값이 0 이면 가짜 git 이 PATH 에 걸리지 않았다는 뜻이고, 그러면 위 단언은
	// 호출이 없었음을 보인 것이 아니라 관측이 없었음을 보인 것이 된다.
	Branch(repo, t.TempDir())
	if n := tally(); n == 0 {
		t.Error("저장소에서는 git 을 부른다 — 가짜 git 이 PATH 에 걸리지 않았다")
	}
}

func TestMissingOrUnreadableCWDYieldsEmptyBranch(t *testing.T) {
	// 셸은 [ -n "$cwd" ] && [ -d "$cwd" ] 로 먼저 걸러 git 을 부르지도 않는다.
	if got := Branch("", t.TempDir()); got != "" {
		t.Errorf("빈 cwd: %q", got)
	}
	if got := Branch(filepath.Join(t.TempDir(), "gone"), t.TempDir()); got != "" {
		t.Errorf("없는 디렉터리: %q", got)
	}
}

func TestCacheHitDoesNotInvokeGit(t *testing.T) {
	// 캐시 적중에서 git 을 다시 부르면 렌더마다 프로세스가 하나 늘어 이식의 이유가 사라진다.
	dir, cache := newRepo(t, "wip"), t.TempDir()
	if got := Branch(dir, cache); got != "wip" {
		t.Fatalf("사전 준비 실패: %q", got)
	}
	tally := blockGit(t)
	if got := Branch(dir, cache); got != "wip" {
		t.Fatalf("캐시 적중에서 Branch = %q, want wip", got)
	}
	if n := tally(); n != 0 {
		t.Errorf("캐시 적중인데 git 을 %d회 불렀다", n)
	}
}

// blockGit puts a git on PATH that records its calls and then fails, so a call that
// should not happen is both counted and unable to answer.
func blockGit(t *testing.T) func() int {
	t.Helper()
	dir := t.TempDir()
	calls := filepath.Join(dir, "calls")
	script := "#!/bin/sh\nprintf 'call\\n' >> \"" + calls + "\"\nexit 1\n"
	if err := os.WriteFile(filepath.Join(dir, "git"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	return func() int {
		b, _ := os.ReadFile(calls)
		return strings.Count(string(b), "\n")
	}
}
