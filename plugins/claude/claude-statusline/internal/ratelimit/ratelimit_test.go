package ratelimit

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func c(pct int, reset int64) Sample {
	return Sample{Present: true, HasReset: true, Pct: pct, ResetsAt: reset}
}

const sid = "11111111-2222-3333-4444-555555555555"

// cacheOf is where a session's windows live under cacheDir.
func cacheOf(cacheDir, id string) string {
	return filepath.Join(cacheDir, "rate-limits", id+".env")
}

func TestLoadMissingFileYieldsAbsentSamples(t *testing.T) {
	p := Load(filepath.Join(t.TempDir(), "none.env"))
	if p.Five.Present || p.Week.Present {
		t.Fatalf("파일이 없으면 아무 표본도 없어야 한다: %+v", p)
	}
}

func TestStoreThenLoadRoundTrips(t *testing.T) {
	file := filepath.Join(t.TempDir(), "x.env")
	want := Pair{Five: c(24, 1700000000), Week: c(41, 1700600000)}
	if err := Store(file, want); err != nil {
		t.Fatalf("Store: %v", err)
	}
	if got := Load(file); got != want {
		t.Fatalf("Load = %+v, want %+v", got, want)
	}
}

func TestStoreIsAtomicAndLeavesNoTempFile(t *testing.T) {
	dir := t.TempDir()
	if err := Store(filepath.Join(dir, "x.env"), Pair{Five: c(24, 1700000000)}); err != nil {
		t.Fatalf("Store: %v", err)
	}
	ents, _ := os.ReadDir(dir)
	if len(ents) != 1 || ents[0].Name() != "x.env" {
		t.Fatalf("임시 파일이 남았다: %v", ents)
	}
}

func TestLoadIgnoresGarbageLines(t *testing.T) {
	file := filepath.Join(t.TempDir(), "x.env")
	os.WriteFile(file, []byte("fivePct=abc\nfiveReset=\nweekPct=41\nweekReset=1700600000\nnonsense\n"), 0o600)
	p := Load(file)
	if p.Five.Present {
		t.Fatalf("숫자가 아닌 값을 표본으로 받아들이면 안 된다: %+v", p.Five)
	}
	if !p.Week.Complete() || p.Week.Pct != 41 {
		t.Fatalf("멀쩡한 창까지 버리면 안 된다: %+v", p.Week)
	}
}

func TestStoreCreatesCacheDirWhenMissing(t *testing.T) {
	file := filepath.Join(t.TempDir(), "not-yet", "x.env")
	if err := Store(file, Pair{Five: c(1, 2)}); err != nil {
		t.Fatalf("Store: %v", err)
	}
}

func TestLoadTreatsAWindowWithoutResetAsAbsent(t *testing.T) {
	// Store 는 불완전한 창을 쓰지 않으므로 리셋 없는 캐시 항목은 손상이다. 만료를 판정할 수
	// 없는 값을 표본으로 되살리면 지난 창의 소진율이 영원히 남는다.
	file := filepath.Join(t.TempDir(), "x.env")
	os.WriteFile(file, []byte("fivePct=24\n"), 0o600)
	if p := Load(file); p.Five.Present {
		t.Fatalf("리셋 없는 캐시 항목은 부재로 읽어야 한다: %+v", p.Five)
	}
}

func TestResolveShowsCachedValueWhenStdinHasNone(t *testing.T) {
	dir := t.TempDir()
	Store(cacheOf(dir, sid), Pair{Five: c(24, 2000), Week: c(41, 3000)})
	got := Resolve(dir, sid, Pair{}, 1000)
	if got.Five.Pct != 24 || got.Week.Pct != 41 {
		t.Fatalf("세션이 값을 못 받았으면 캐시가 공급해야 한다: %+v", got)
	}
}

func TestResolveHidesExpiredCachedWindow(t *testing.T) {
	dir := t.TempDir()
	Store(cacheOf(dir, sid), Pair{Five: c(94, 1000), Week: c(41, 3000)})
	got := Resolve(dir, sid, Pair{}, 2000) // 5시간 창의 리셋 시각이 지났다
	if got.Five.Present {
		t.Fatalf("지난 창의 소진율은 더 이상 참이 아니다: %+v", got.Five)
	}
	if !got.Week.Present {
		t.Fatalf("한 창이 만료돼도 다른 창은 살아야 한다: %+v", got.Week)
	}
}

func TestResolveWritesWhenLiveSampleWins(t *testing.T) {
	dir := t.TempDir()
	Store(cacheOf(dir, sid), Pair{Five: c(24, 2000)})
	Resolve(dir, sid, Pair{Five: c(31, 2000)}, 1000)
	if after := Load(cacheOf(dir, sid)); after.Five.Pct != 31 {
		t.Fatalf("새 표본이 저장되지 않았다: %+v", after.Five)
	}
}

func TestResolveDoesNotWriteWhenNothingChanged(t *testing.T) {
	dir := t.TempDir()
	Store(cacheOf(dir, sid), Pair{Five: c(24, 2000)})
	path := cacheOf(dir, sid)
	before, _ := os.Stat(path)
	time.Sleep(10 * time.Millisecond)
	Resolve(dir, sid, Pair{Five: c(24, 2000)}, 1000)
	after, _ := os.Stat(path)
	if !before.ModTime().Equal(after.ModTime()) {
		t.Fatal("값이 그대로면 쓰지 않아야 한다 — 렌더마다 쓰면 자원만 쓴다")
	}
}

func TestResolveDisplaysButNeverStoresASampleWithoutReset(t *testing.T) {
	dir := t.TempDir()
	live := Pair{Five: Sample{Present: true, Pct: 77}}
	got := Resolve(dir, sid, live, 1000)
	if got.Five.Pct != 77 {
		t.Fatalf("자기 세션이 받은 값은 그대로 그린다: %+v", got.Five)
	}
	if _, err := os.Stat(cacheOf(dir, sid)); !os.IsNotExist(err) {
		t.Fatal("유효 기간을 판정할 수 없는 표본은 저장하지 않는다")
	}
}

func TestResolveKeepsExpiredEntryInFileUntilOverwritten(t *testing.T) {
	// 만료 판정은 그릴 때만 한다. 지우는 쓰기를 따로 두면 병합하는 쓰기와 경합만 는다.
	dir := t.TempDir()
	Store(cacheOf(dir, sid), Pair{Five: c(94, 1000), Week: c(41, 3000)})
	Resolve(dir, sid, Pair{}, 2000)
	if after := Load(cacheOf(dir, sid)); after.Five.Pct != 94 {
		t.Fatalf("만료됐다고 파일에서 지우면 안 된다: %+v", after.Five)
	}
}

func TestResolveShowsLiveSampleEvenWhenCacheHoldsALaterReset(t *testing.T) {
	// 실제로 관측한 상태다. 5시간 창은 굴러가는 창이라 리셋 시각이 앞선 창으로 되돌아갈
	// 수 있고, 그때 캐시의 더 먼 리셋이 지금 페이로드를 계속 이겨 화면이 얼어붙었다.
	dir := t.TempDir()
	Store(cacheOf(dir, sid), Pair{Five: c(1, 3000), Week: c(56, 9000)})
	got := Resolve(dir, sid, Pair{Five: c(81, 2000), Week: c(78, 8000)}, 1000)
	if got.Five.Pct != 81 || got.Week.Pct != 78 {
		t.Fatalf("페이로드가 화면을 차지해야 한다: %+v", got)
	}
	if after := Load(cacheOf(dir, sid)); after.Five.Pct != 81 || after.Week.Pct != 78 {
		t.Fatalf("페이로드가 파일에도 남아야 한다: %+v", after)
	}
}

func TestResolveFollowsLiveSampleDownwardWithinOneWindow(t *testing.T) {
	// 리셋이 같아도 페이로드가 낮으면 낮은 값이 지금의 상태다. 계정이 바뀌었든 서버가
	// 다시 계산했든, 화면이 따라야 할 값은 이 세션이 방금 받은 값 하나뿐이다.
	dir := t.TempDir()
	Store(cacheOf(dir, sid), Pair{Five: c(60, 2000)})
	got := Resolve(dir, sid, Pair{Five: c(24, 2000)}, 1000)
	if got.Five.Pct != 24 {
		t.Fatalf("페이로드를 따라 내려가야 한다: %+v", got.Five)
	}
	if after := Load(cacheOf(dir, sid)); after.Five.Pct != 24 {
		t.Fatalf("파일도 페이로드를 따라야 한다: %+v", after.Five)
	}
}

// R11 — a window one session saw is never drawn in another session.

func TestSessionsNeverSeeEachOthersWindows(t *testing.T) {
	dir := t.TempDir()
	Resolve(dir, "session-a", Pair{Five: c(24, 2000), Week: c(41, 3000)}, 1000)
	got := Resolve(dir, "session-b", Pair{}, 1000)
	if got.Five.Present || got.Week.Present {
		t.Fatalf("다른 세션의 창이 섞였다: %+v", got)
	}
	if again := Resolve(dir, "session-a", Pair{}, 1000); again.Five.Pct != 24 || again.Week.Pct != 41 {
		t.Fatalf("자기 세션의 캐시는 남아 있어야 한다: %+v", again)
	}
}

func TestInvalidSessionIDsHaveNoCache(t *testing.T) {
	dir := t.TempDir()
	for _, id := range []string{"", "../x", "a/b", "a b", "a.b", strings.Repeat("a", 65), "x\n"} {
		got := Resolve(dir, id, Pair{Five: c(24, 2000)}, 1000)
		if got.Five.Pct != 24 {
			t.Errorf("%q: 페이로드 값은 그대로 그려야 한다: %+v", id, got)
		}
		if again := Resolve(dir, id, Pair{}, 1000); again.Five.Present {
			t.Errorf("%q: 캐시 없이 값이 남았다: %+v", id, again)
		}
	}
	var left []string
	filepath.WalkDir(dir, func(p string, d os.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			left = append(left, p)
		}
		return nil
	})
	if len(left) != 0 {
		t.Errorf("무효 id 가 파일을 남겼다: %v", left)
	}
}

func TestSharedCacheFileIsNeitherReadNorWritten(t *testing.T) {
	dir := t.TempDir()
	shared := filepath.Join(dir, "rate-limits.env")
	body := "fivePct=99\nfiveReset=4102444800\nweekPct=98\nweekReset=4102444800\n"
	os.WriteFile(shared, []byte(body), 0o600)
	got := Resolve(dir, sid, Pair{}, 1000)
	if got.Five.Present || got.Week.Present {
		t.Fatalf("공용 파일의 값이 그려졌다: %+v", got)
	}
	Resolve(dir, sid, Pair{Five: c(10, 4102444800)}, 1000)
	if b, _ := os.ReadFile(shared); string(b) != body {
		t.Fatalf("공용 파일이 바뀌었다: %q", b)
	}
}

func TestWritingPrunesSessionCachesOlderThanTwoDays(t *testing.T) {
	dir := t.TempDir()
	old := cacheOf(dir, "old-session")
	Store(old, Pair{Five: c(1, 2)})
	at := time.Now().Add(-49 * time.Hour)
	os.Chtimes(old, at, at)
	recent := cacheOf(dir, "recent-session")
	Store(recent, Pair{Five: c(1, 2)})
	at = time.Now().Add(-47 * time.Hour)
	os.Chtimes(recent, at, at)

	now := time.Now().Unix()
	Resolve(dir, sid, Pair{Five: c(24, now+9000)}, now)
	if _, err := os.Stat(old); !os.IsNotExist(err) {
		t.Error("이틀 넘은 캐시가 남았다")
	}
	if _, err := os.Stat(recent); err != nil {
		t.Error("이틀 안의 다른 세션 캐시가 지워졌다")
	}
	if _, err := os.Stat(cacheOf(dir, sid)); err != nil {
		t.Error("자기 캐시가 없다")
	}
}

// R8 — a window that changes before it ends is a doubt about the account.

func fp(t *testing.T) (dir string) { t.Helper(); return t.TempDir() }

var week = []Window{WindowWeek}
var both = []Window{WindowFive, WindowWeek}

func TestFingerprintFlagsALiveWindowThatChangesBeforeItEnds(t *testing.T) {
	dir := fp(t)
	base := Pair{Week: c(10, 100_000)}
	if Fingerprint(dir, sid, 1, week, base, 1000) {
		t.Fatal("첫 관측으로 기준선을 잡을 뿐 경고하지 않는다")
	}
	changed := Pair{Week: c(10, 150_000)}
	if Fingerprint(dir, sid, 1, week, changed, 2000) {
		t.Fatal("바뀐 값을 처음 본 순간에는 경고하지 않는다")
	}
	if Fingerprint(dir, sid, 1, week, changed, 2060) {
		t.Fatal("60초 이내 변동은 경고하지 않는다")
	}
	if !Fingerprint(dir, sid, 1, week, changed, 2061) {
		t.Fatal("창이 끝나기 전에 60초 넘게 다른 값이면 경고해야 한다")
	}
	if Fingerprint(dir, sid, 1, week, base, 2100) {
		t.Fatal("기준선 값으로 돌아오면 경고가 풀린다")
	}
	if Fingerprint(dir, sid, 1, week, changed, 2200) {
		t.Fatal("돌아왔다가 다시 바뀌면 시간을 처음부터 센다")
	}
}

func TestFingerprintIgnoresAChangeAfterTheBaselineWindowEnded(t *testing.T) {
	dir := fp(t)
	Fingerprint(dir, sid, 1, week, Pair{Week: c(10, 5000)}, 1000)
	next := Pair{Week: c(2, 5000+604800)}
	for _, now := range []int64{5000, 5100, 5200} {
		if Fingerprint(dir, sid, 1, week, next, now) {
			t.Fatalf("주간 갱신(now=%d)은 정상이다", now)
		}
	}
	// 새 창이 새 기준선이다: 그 창 안의 변화는 다시 경고한다.
	other := Pair{Week: c(2, 5000+604800+3600)}
	Fingerprint(dir, sid, 1, week, other, 6000)
	if !Fingerprint(dir, sid, 1, week, other, 6100) {
		t.Fatal("새 기준선 뒤의 변화는 경고해야 한다")
	}
}

func TestFingerprintTakesANewBaselineWhenTheAnchorChanges(t *testing.T) {
	dir := fp(t)
	Fingerprint(dir, sid, 1, week, Pair{Week: c(10, 100_000)}, 1000)
	changed := Pair{Week: c(10, 150_000)}
	Fingerprint(dir, sid, 1, week, changed, 2000)
	if !Fingerprint(dir, sid, 1, week, changed, 2100) {
		t.Fatal("전제: 같은 앵커에서는 경고한다")
	}
	// /login 으로 앵커 시각이 바뀌었다: 새 계정의 창이 기준이다.
	if Fingerprint(dir, sid, 2, week, changed, 2200) {
		t.Fatal("앵커가 바뀌면 경고하지 않고 기준선을 새로 잡는다")
	}
	if Fingerprint(dir, sid, 2, week, changed, 2300) {
		t.Fatal("새 기준선과 같은 값은 경고하지 않는다")
	}
}

func TestFingerprintNeedsALiveCompleteWindow(t *testing.T) {
	dir := fp(t)
	if Fingerprint(dir, sid, 1, week, Pair{}, 1000) {
		t.Fatal("창이 없으면 경고하지 않는다")
	}
	if Fingerprint(dir, sid, 1, week, Pair{Week: Sample{Present: true, Pct: 5}}, 1100) {
		t.Fatal("리셋 시각 없는 표본은 지문이 아니다")
	}
	Fingerprint(dir, sid, 1, week, Pair{Week: c(10, 100_000)}, 1200)
	if Fingerprint(dir, sid, 1, week, Pair{}, 5000) {
		t.Fatal("페이로드에 창이 빠진 렌더는 경고하지 않는다")
	}
}

func TestFingerprintWindowListDecidesWhichWindowsCount(t *testing.T) {
	baseline := Pair{Five: c(10, 20_000), Week: c(10, 100_000)}
	fiveChanged := Pair{Five: c(10, 20_900), Week: c(10, 100_000)}

	weekOnly := fp(t)
	Fingerprint(weekOnly, sid, 1, week, baseline, 1000)
	Fingerprint(weekOnly, sid, 1, week, fiveChanged, 2000)
	if Fingerprint(weekOnly, sid, 1, week, fiveChanged, 2100) {
		t.Error("7일 창만 지문이면 5시간 창 변화는 무시한다")
	}
	withFive := fp(t)
	Fingerprint(withFive, sid, 1, both, baseline, 1000)
	Fingerprint(withFive, sid, 1, both, fiveChanged, 2000)
	if !Fingerprint(withFive, sid, 1, both, fiveChanged, 2100) {
		t.Error("5시간 창을 지문에 넣으면 그 창의 변화도 경고한다")
	}
}

func TestFingerprintSessionsAreIndependentAndInvalidIDsAreSkipped(t *testing.T) {
	dir := fp(t)
	Fingerprint(dir, "a", 1, week, Pair{Week: c(10, 100_000)}, 1000)
	Fingerprint(dir, "b", 1, week, Pair{Week: c(10, 150_000)}, 1000)
	if Fingerprint(dir, "b", 1, week, Pair{Week: c(10, 150_000)}, 2000) {
		t.Error("세션 b 의 기준선은 자기 값이다")
	}
	for _, id := range []string{"", "../x", "a b"} {
		if Fingerprint(dir, id, 1, week, Pair{Week: c(1, 2)}, 1000) {
			t.Errorf("%q 는 경고하면 안 된다", id)
		}
	}
	ents, _ := os.ReadDir(dir)
	if len(ents) != 2 {
		t.Errorf("파일 %d개, 세션 a·b 둘만 있어야 한다", len(ents))
	}
}

func TestFingerprintWritePrunesOldFiles(t *testing.T) {
	dir := fp(t)
	old := filepath.Join(dir, "old.env")
	os.WriteFile(old, []byte("anchor=1\n"), 0o600)
	at := time.Now().Add(-31 * 24 * time.Hour)
	os.Chtimes(old, at, at)
	now := time.Now().Unix()
	Fingerprint(dir, sid, 1, week, Pair{Week: c(10, now+100_000)}, now)
	if _, err := os.Stat(old); !os.IsNotExist(err) {
		t.Error("30일 넘은 지문 파일이 남았다")
	}
}
