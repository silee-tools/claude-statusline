package width

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// fakePS puts a `ps` on PATH that answers from a queue file, one line per call, and
// tallies its calls. 조상 탐색이 몇 단계까지 올라가는지는 호출 횟수로만 관찰되고, 실제
// 프로세스 트리는 실행 환경마다 달라 그 횟수를 고정하지 못한다.
func fakePS(t *testing.T, answers ...string) (tally func() int) {
	t.Helper()
	dir := t.TempDir()
	queue := filepath.Join(dir, "queue")
	calls := filepath.Join(dir, "calls")
	if err := os.WriteFile(queue, []byte(strings.Join(answers, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(calls, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/sh\n" +
		"printf 'call\\n' >> \"$PS_TALLY\"\n" +
		"n=$(wc -l < \"$PS_TALLY\" | tr -d ' ')\n" +
		"line=$(sed -n \"${n}p\" \"$PS_QUEUE\" 2>/dev/null)\n" +
		"[ -z \"$line\" ] && exit 1\n" +
		"printf '%s\\n' \"$line\"\n"
	if err := os.WriteFile(filepath.Join(dir, "ps"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PS_TALLY", calls)
	t.Setenv("PS_QUEUE", queue)
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	return func() int {
		b, err := os.ReadFile(calls)
		if err != nil {
			t.Fatal(err)
		}
		return strings.Count(string(b), "\n")
	}
}

func readCache(t *testing.T, cacheDir string) (ppid, path string, ok bool) {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(cacheDir, "tty-path.env"))
	if err != nil {
		return "", "", false
	}
	for _, line := range strings.Split(string(b), "\n") {
		k, v, found := strings.Cut(line, "=")
		if !found {
			continue
		}
		switch k {
		case "ppid":
			ppid = v
		case "path":
			path = v
		}
	}
	return ppid, path, true
}

func TestOverrideWinsAndMustBeNumeric(t *testing.T) {
	t.Setenv("CLAUDE_STATUSLINE_WIDTH", "97")
	tally := fakePS(t, "ttys001 100")
	if c, ok := Terminal(t.TempDir()); !ok || c != 97 {
		t.Fatalf("주입 폭을 그대로 써야 한다: %d %v", c, ok)
	}
	if n := tally(); n != 0 {
		t.Errorf("오버라이드는 조상 탐색을 하지 않는다: ps %d회", n)
	}
	t.Setenv("CLAUDE_STATUSLINE_WIDTH", "abc")
	// 숫자가 아니면 무시하고 프로브로 진행한다. 오류로 죽지 않아야 한다.
	_, _ = Terminal(t.TempDir())
	if n := tally(); n == 0 {
		t.Error("비숫자 오버라이드는 프로브를 실제로 태워야 한다")
	}
}

func TestUndeterminedWidthReportsNotOK(t *testing.T) {
	t.Setenv("CLAUDE_STATUSLINE_WIDTH", "")
	t.Setenv("CLAUDE_STATUSLINE_TTY_DIR", filepath.Join(t.TempDir(), "missing-dev"))
	if _, ok := Terminal(t.TempDir()); ok {
		t.Fatal("판정 불가일 때 ok=true 를 내면 호출자가 넓은 레이아웃 폴백을 못 쓴다")
	}
}

func TestCacheIsKeyedByParentPID(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "tty-path.env"),
		[]byte("ppid=999999\npath=/dev/nope\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CLAUDE_STATUSLINE_WIDTH", "")
	t.Setenv("CLAUDE_STATUSLINE_TTY_DIR", filepath.Join(dir, "missing-dev"))
	fakePS(t, "?? 1", "?? 2", "?? 3", "?? 4")
	// 부모 pid 가 다르므로 캐시를 쓰지 않고 프로브로 간다. 죽지 않고 판정 불가를 내면 된다.
	if _, ok := Terminal(dir); ok {
		t.Fatal("다른 ppid 의 캐시를 재사용하면 안 된다")
	}
}

// 아래 넷은 경로 결정 로직을 검증한다. 창 크기 조회 자체는 실제 터미널 장치가 있어야
// 성립해 호스트마다 갈리므로, 장치를 여는 부분과 경로를 정하는 부분을 나눠 후자만 단언한다.
func TestTTYPathUsesTheParentTTY(t *testing.T) {
	dev := t.TempDir()
	if err := os.WriteFile(filepath.Join(dev, "ttys003"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CLAUDE_STATUSLINE_TTY_DIR", dev)
	tally := fakePS(t, "ttys003 300")
	got, ok := ttyPath(t.TempDir())
	if !ok || got != filepath.Join(dev, "ttys003") {
		t.Fatalf("ttyPath = %q %v", got, ok)
	}
	if n := tally(); n != 1 {
		t.Errorf("부모가 tty 를 가지면 ps 는 한 번이다: %d", n)
	}
}

func TestTTYPathClimbsToAnAncestor(t *testing.T) {
	dev := t.TempDir()
	t.Setenv("CLAUDE_STATUSLINE_TTY_DIR", dev)
	tally := fakePS(t, "?? 401", "?? 402", "ttys004 403")
	got, ok := ttyPath(t.TempDir())
	if !ok || got != filepath.Join(dev, "ttys004") {
		t.Fatalf("여러 단계 위 조상의 tty 를 써야 한다: %q %v", got, ok)
	}
	if n := tally(); n != 3 {
		t.Errorf("tty 를 찾을 때까지 ps 를 반복 호출: %d, want 3", n)
	}
}

func TestTTYPathStopsAfterFourAncestors(t *testing.T) {
	// 넉넉히 여섯 줄을 준비해 캡이 4에서 멈추는지 함께 확인한다.
	t.Setenv("CLAUDE_STATUSLINE_TTY_DIR", t.TempDir())
	tally := fakePS(t, "?? 501", "?? 502", "?? 503", "?? 504", "?? 505", "?? 506")
	if _, ok := ttyPath(t.TempDir()); ok {
		t.Fatal("tty 없는 조상 사슬이면 판정 불가여야 한다")
	}
	if n := tally(); n != 4 {
		t.Errorf("최대 4단계까지만 ps 호출: %d, want 4", n)
	}
}

func TestTTYPathCachesThePathAndSkipsPSOnAHit(t *testing.T) {
	dev, cache := t.TempDir(), t.TempDir()
	t.Setenv("CLAUDE_STATUSLINE_TTY_DIR", dev)
	tally := fakePS(t, "ttys007 700")
	first, ok := ttyPath(cache)
	if !ok {
		t.Fatal("사전 준비 실패")
	}
	ppid, path, exists := readCache(t, cache)
	if !exists || path != first || ppid != strconv.Itoa(os.Getppid()) {
		t.Fatalf("캐시가 부모 pid 로 키를 삼아 경로를 담아야 한다: %q %q %v", ppid, path, exists)
	}
	second, ok := ttyPath(cache)
	if !ok || second != first {
		t.Fatalf("캐시 히트에서 같은 경로: %q %q", first, second)
	}
	if n := tally(); n != 1 {
		t.Errorf("캐시 히트면 ps 미호출: 누적 %d, want 1", n)
	}
}

func TestTerminalDiscardsACacheWhoseDeviceIsGone(t *testing.T) {
	// 캐시된 경로로 창 크기 조회가 실패하면 그 항목을 버린다. 버리지 않으면 다음 렌더도
	// 같은 죽은 경로를 재사용해 계속 판정 불가만 낸다.
	dev, cache := t.TempDir(), t.TempDir()
	t.Setenv("CLAUDE_STATUSLINE_WIDTH", "")
	t.Setenv("CLAUDE_STATUSLINE_TTY_DIR", dev)
	fakePS(t, "ttys008 800")
	if _, ok := Terminal(cache); ok {
		t.Fatal("존재하지 않는 장치로는 폭을 정할 수 없다")
	}
	if _, _, exists := readCache(t, cache); exists {
		t.Fatal("죽은 캐시 항목을 버려야 한다")
	}
}
