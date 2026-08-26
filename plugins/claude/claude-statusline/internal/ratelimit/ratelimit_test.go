package ratelimit

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func c(pct int, reset int64) Sample {
	return Sample{Present: true, HasReset: true, Pct: pct, ResetsAt: reset}
}

func TestLoadMissingFileYieldsAbsentSamples(t *testing.T) {
	p := Load(t.TempDir())
	if p.Five.Present || p.Week.Present {
		t.Fatalf("파일이 없으면 아무 표본도 없어야 한다: %+v", p)
	}
}

func TestStoreThenLoadRoundTrips(t *testing.T) {
	dir := t.TempDir()
	want := Pair{Five: c(24, 1700000000), Week: c(41, 1700600000)}
	if err := Store(dir, want); err != nil {
		t.Fatalf("Store: %v", err)
	}
	if got := Load(dir); got != want {
		t.Fatalf("Load = %+v, want %+v", got, want)
	}
}

func TestStoreIsAtomicAndLeavesNoTempFile(t *testing.T) {
	dir := t.TempDir()
	if err := Store(dir, Pair{Five: c(24, 1700000000)}); err != nil {
		t.Fatalf("Store: %v", err)
	}
	ents, _ := os.ReadDir(dir)
	if len(ents) != 1 || ents[0].Name() != "rate-limits.env" {
		t.Fatalf("임시 파일이 남았다: %v", ents)
	}
}

func TestLoadIgnoresGarbageLines(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "rate-limits.env"),
		[]byte("fivePct=abc\nfiveReset=\nweekPct=41\nweekReset=1700600000\nnonsense\n"), 0o600)
	p := Load(dir)
	if p.Five.Present {
		t.Fatalf("숫자가 아닌 값을 표본으로 받아들이면 안 된다: %+v", p.Five)
	}
	if !p.Week.Complete() || p.Week.Pct != 41 {
		t.Fatalf("멀쩡한 창까지 버리면 안 된다: %+v", p.Week)
	}
}

func TestStoreCreatesCacheDirWhenMissing(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "not-yet")
	if err := Store(dir, Pair{Five: c(1, 2)}); err != nil {
		t.Fatalf("Store: %v", err)
	}
}

func TestLoadTreatsAWindowWithoutResetAsAbsent(t *testing.T) {
	// Store 는 불완전한 창을 쓰지 않으므로 리셋 없는 캐시 항목은 손상이다. 만료를 판정할 수
	// 없는 값을 표본으로 되살리면 지난 창의 소진율이 영원히 남는다.
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "rate-limits.env"), []byte("fivePct=24\n"), 0o600)
	if p := Load(dir); p.Five.Present {
		t.Fatalf("리셋 없는 캐시 항목은 부재로 읽어야 한다: %+v", p.Five)
	}
}

func TestResolveShowsCachedValueWhenStdinHasNone(t *testing.T) {
	dir := t.TempDir()
	Store(dir, Pair{Five: c(24, 2000), Week: c(41, 3000)})
	got := Resolve(dir, Pair{}, 1000)
	if got.Five.Pct != 24 || got.Week.Pct != 41 {
		t.Fatalf("세션이 값을 못 받았으면 캐시가 공급해야 한다: %+v", got)
	}
}

func TestResolveHidesExpiredCachedWindow(t *testing.T) {
	dir := t.TempDir()
	Store(dir, Pair{Five: c(94, 1000), Week: c(41, 3000)})
	got := Resolve(dir, Pair{}, 2000) // 5시간 창의 리셋 시각이 지났다
	if got.Five.Present {
		t.Fatalf("지난 창의 소진율은 더 이상 참이 아니다: %+v", got.Five)
	}
	if !got.Week.Present {
		t.Fatalf("한 창이 만료돼도 다른 창은 살아야 한다: %+v", got.Week)
	}
}

func TestResolveWritesWhenLiveSampleWins(t *testing.T) {
	dir := t.TempDir()
	Store(dir, Pair{Five: c(24, 2000)})
	Resolve(dir, Pair{Five: c(31, 2000)}, 1000)
	if after := Load(dir); after.Five.Pct != 31 {
		t.Fatalf("새 표본이 저장되지 않았다: %+v", after.Five)
	}
}

func TestResolveDoesNotWriteWhenNothingChanged(t *testing.T) {
	dir := t.TempDir()
	Store(dir, Pair{Five: c(24, 2000)})
	path := filepath.Join(dir, "rate-limits.env")
	before, _ := os.Stat(path)
	time.Sleep(10 * time.Millisecond)
	Resolve(dir, Pair{Five: c(24, 2000)}, 1000)
	after, _ := os.Stat(path)
	if !before.ModTime().Equal(after.ModTime()) {
		t.Fatal("값이 그대로면 쓰지 않아야 한다 — 렌더마다 쓰면 자원만 쓴다")
	}
}

func TestResolveDisplaysButNeverStoresASampleWithoutReset(t *testing.T) {
	dir := t.TempDir()
	live := Pair{Five: Sample{Present: true, Pct: 77}}
	got := Resolve(dir, live, 1000)
	if got.Five.Pct != 77 {
		t.Fatalf("자기 세션이 받은 값은 그대로 그린다: %+v", got.Five)
	}
	if _, err := os.Stat(filepath.Join(dir, "rate-limits.env")); !os.IsNotExist(err) {
		t.Fatal("유효 기간을 판정할 수 없는 표본은 저장하지 않는다")
	}
}

func TestResolveKeepsExpiredEntryInFileUntilOverwritten(t *testing.T) {
	// 만료 판정은 그릴 때만 한다. 지우는 쓰기를 따로 두면 병합하는 쓰기와 경합만 는다.
	dir := t.TempDir()
	Store(dir, Pair{Five: c(94, 1000), Week: c(41, 3000)})
	Resolve(dir, Pair{}, 2000)
	if after := Load(dir); after.Five.Pct != 94 {
		t.Fatalf("만료됐다고 파일에서 지우면 안 된다: %+v", after.Five)
	}
}

func TestResolveShowsLiveSampleEvenWhenCacheHoldsALaterReset(t *testing.T) {
	// 실제로 관측한 상태다. 5시간 창은 굴러가는 창이라 리셋 시각이 앞선 창으로 되돌아갈
	// 수 있고, 그때 캐시의 더 먼 리셋이 지금 페이로드를 계속 이겨 화면이 얼어붙었다.
	dir := t.TempDir()
	Store(dir, Pair{Five: c(1, 3000), Week: c(56, 9000)})
	got := Resolve(dir, Pair{Five: c(81, 2000), Week: c(78, 8000)}, 1000)
	if got.Five.Pct != 81 || got.Week.Pct != 78 {
		t.Fatalf("페이로드가 화면을 차지해야 한다: %+v", got)
	}
	if after := Load(dir); after.Five.Pct != 81 || after.Week.Pct != 78 {
		t.Fatalf("페이로드가 파일에도 남아야 한다: %+v", after)
	}
}

func TestResolveFollowsLiveSampleDownwardWithinOneWindow(t *testing.T) {
	// 리셋이 같아도 페이로드가 낮으면 낮은 값이 지금의 상태다. 계정이 바뀌었든 서버가
	// 다시 계산했든, 화면이 따라야 할 값은 이 세션이 방금 받은 값 하나뿐이다.
	dir := t.TempDir()
	Store(dir, Pair{Five: c(60, 2000)})
	got := Resolve(dir, Pair{Five: c(24, 2000)}, 1000)
	if got.Five.Pct != 24 {
		t.Fatalf("페이로드를 따라 내려가야 한다: %+v", got.Five)
	}
	if after := Load(dir); after.Five.Pct != 24 {
		t.Fatalf("파일도 페이로드를 따라야 한다: %+v", after.Five)
	}
}
