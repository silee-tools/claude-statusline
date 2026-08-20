package ratelimit

import (
	"os"
	"path/filepath"
	"testing"
)

func c(pct int, reset int64) Sample {
	return Sample{Present: true, HasReset: true, Pct: pct, ResetsAt: reset}
}

func TestNewerPrefersLaterResetEvenWhenPctIsLower(t *testing.T) {
	// 창이 바뀌면 소진율은 떨어지고 리셋 시각은 앞으로 간다. 리셋 시각이 이겨야 한다.
	old, fresh := c(94, 1000), c(3, 2000)
	if got := Newer(old, fresh); got != fresh {
		t.Fatalf("새 창이 이겨야 한다: %+v", got)
	}
	if got := Newer(fresh, old); got != fresh {
		t.Fatalf("인자 순서가 결과를 바꾸면 안 된다: %+v", got)
	}
}

func TestNewerPrefersHigherPctWithinSameWindow(t *testing.T) {
	// 한 창 안에서 소진율은 줄지 않는다. 낮은 값은 낡은 표본이다.
	stale, fresh := c(24, 1000), c(31, 1000)
	if got := Newer(stale, fresh); got != fresh {
		t.Fatalf("같은 창에서는 높은 소진율이 이겨야 한다: %+v", got)
	}
}

func TestNewerIsIdempotentAndCommutative(t *testing.T) {
	a, b := c(24, 1000), c(31, 1000)
	if Newer(a, a) != a {
		t.Fatal("같은 값을 병합하면 그대로여야 한다")
	}
	if Newer(a, b) != Newer(b, a) {
		t.Fatal("병합은 순서에 무관해야 한다 — 동시 쓰기가 이 성질로 수렴한다")
	}
}

func TestIncompleteSampleAlwaysLoses(t *testing.T) {
	complete := c(24, 1000)
	noReset := Sample{Present: true, Pct: 99}
	absent := Sample{}
	if got := Newer(noReset, complete); got != complete {
		t.Fatalf("유효 기간을 모르는 표본이 이기면 안 된다: %+v", got)
	}
	if got := Newer(absent, complete); got != complete {
		t.Fatalf("없는 표본이 이기면 안 된다: %+v", got)
	}
	if got := Newer(absent, noReset); got.Complete() {
		t.Fatalf("둘 다 불완전하면 완전한 값이 나올 수 없다: %+v", got)
	}
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
