package ratelimit

import "testing"

func c(pct int, reset int64) Sample { return Sample{Present: true, HasReset: true, Pct: pct, ResetsAt: reset} }

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
