package segments

import (
	"os"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"
	"time"
)

// returnsInTime fails the test if f is still running after two seconds. A read that waits for
// a writer of the FIFO is then released, so a failing test does not leave it behind.
func returnsInTime(t *testing.T, fifo string, f func()) {
	t.Helper()
	done := make(chan struct{})
	go func() { f(); close(done) }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		if h, err := os.OpenFile(fifo, os.O_RDWR|syscall.O_NONBLOCK, 0); err == nil {
			h.Close()
		}
		t.Fatalf("%s: FIFO 에서 멈췄다", filepath.Base(fifo))
	}
}

// replaceWithFifo puts a FIFO at path, where a file may be.
func replaceWithFifo(t *testing.T, path string) {
	t.Helper()
	os.Remove(path)
	if err := syscall.Mkfifo(path, 0o600); err != nil {
		t.Fatal(err)
	}
}

// replaceWithLink moves the file at path (or writes body if there is none) elsewhere and
// leaves a link to it at path.
func replaceWithLink(t *testing.T, path, body string) {
	t.Helper()
	elsewhere := filepath.Join(t.TempDir(), filepath.Base(path))
	if err := os.WriteFile(elsewhere, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	os.Remove(path)
	if err := os.Symlink(elsewhere, path); err != nil {
		t.Fatal(err)
	}
}

func ghSlot(t *testing.T, fifo string, cacheDir, configDir, origin string) (got string) {
	t.Helper()
	returnsInTime(t, fifo, func() { got = plain(GitHubAccount(cacheDir, configDir, ghRoot, origin, 0)) })
	return got
}

// The prompt writes the gh cache, so it is not the statusline's file: a link there is followed,
// but a FIFO, or a link to one, shows nothing instead of holding the render.
func TestTheGhSlotFollowsALinkedPromptCacheAndIsNotHeldByAFifoOrALinkToOne(t *testing.T) {
	cacheDir, configDir := ghFixture(t, "")
	cache := filepath.Join(cacheDir, ghKey)

	replaceWithLink(t, cache, "v2\toctocat\tok\t0")
	if got := ghSlot(t, cache, cacheDir, configDir, ghOrigin); got != "gh@personal" {
		t.Errorf("링크의 캐시: %q, want gh@personal", got)
	}

	replaceWithFifo(t, cache)
	if got := ghSlot(t, cache, cacheDir, configDir, ghOrigin); got != "" {
		t.Errorf("FIFO 캐시: %q, want 빈 문자열", got)
	}

	fifo := filepath.Join(t.TempDir(), "fifo")
	replaceWithFifo(t, fifo)
	os.Remove(cache)
	if err := os.Symlink(fifo, cache); err != nil {
		t.Fatal(err)
	}
	if got := ghSlot(t, fifo, cacheDir, configDir, ghOrigin); got != "" {
		t.Errorf("FIFO 를 가리키는 링크의 캐시: %q, want 빈 문자열", got)
	}
}

// gh-accounts is the user's file, which a dotfile manager may link in; without it the slot
// shows the login as it is.
func TestTheAccountMappingFollowsALinkAndIsNotHeldByAFifo(t *testing.T) {
	cacheDir, configDir := ghFixture(t, "v2\toctocat\tok\t0")
	mapping := filepath.Join(configDir, "claude-statusline", "gh-accounts")

	replaceWithLink(t, mapping, "octocat=linked,214\n")
	if got := ghSlot(t, mapping, cacheDir, configDir, ghOrigin); got != "gh@linked" {
		t.Errorf("링크의 매핑: %q, want gh@linked", got)
	}

	replaceWithFifo(t, mapping)
	if got := ghSlot(t, mapping, cacheDir, configDir, ghOrigin); got != "gh@octocat" {
		t.Errorf("FIFO 매핑: %q, want gh@octocat", got)
	}
}

func TestTheForgejoHostListFollowsALinkAndIsNotHeldByAFifo(t *testing.T) {
	cacheDir, configDir := ghFixture(t, "v2\toctocat\tok\t0")
	hosts := filepath.Join(configDir, "claude-statusline", "forgejo-hosts")
	const origin = "https://forgejo.example.test/o/r.git"

	replaceWithLink(t, hosts, "forgejo.example.test\n")
	if got := ghSlot(t, hosts, cacheDir, configDir, origin); got != "forgejo" {
		t.Errorf("링크의 호스트 목록: %q, want forgejo", got)
	}

	replaceWithFifo(t, hosts)
	if got := ghSlot(t, hosts, cacheDir, configDir, origin); got != "" {
		t.Errorf("FIFO 호스트 목록: %q, want 빈 문자열", got)
	}
}

// staleAWS is an aws login cache whose credentials are old, so the last check decides.
func staleAWS(t *testing.T, now int64) (dir string) {
	t.Helper()
	dir = t.TempDir()
	awsCacheFile(t, dir, "session.json", now-3600)
	return dir
}

// The check record is the statusline's own file, written through a rename: a FIFO in its place
// is replaced by the write that follows, and a link there is not believed.
func TestAFifoWhereTheAWSCheckShouldBeDoesNotHoldTheRenderAndIsReplaced(t *testing.T) {
	const now = int64(1_800_000_000)
	e, dir := newAWSEnv(t), staleAWS(t, now)
	replaceWithFifo(t, e.state)
	var got string
	returnsInTime(t, e.state, func() { got = e.render(dir, now) })
	if got != "aws:?" || e.spawns != 1 {
		t.Errorf("got %q spawns=%d, want aws:? 1", got, e.spawns)
	}
	if fi, err := os.Lstat(e.state); err != nil || !fi.Mode().IsRegular() {
		t.Errorf("FIFO 를 일반 파일로 바꿔 두어야 한다: %v %v", fi, err)
	}
}

// The record is written through a temporary file beside it; a FIFO left at the name that file
// once had must not hold the write, and the record is still stored.
func TestAFifoAtTheAWSCheckTempNameDoesNotHoldTheWrite(t *testing.T) {
	const now = int64(1_800_000_000)
	e, dir := newAWSEnv(t), staleAWS(t, now)
	fifo := e.state + ".tmp"
	replaceWithFifo(t, fifo)
	var got string
	returnsInTime(t, fifo, func() { got = e.render(dir, now) })
	if got != "aws:?" || e.spawns != 1 {
		t.Errorf("got %q spawns=%d, want aws:? 1", got, e.spawns)
	}
	if b, err := os.ReadFile(e.state); err != nil || string(b) != strconv.FormatInt(now, 10)+" ?\n" {
		t.Errorf("확인 기록 = %q, %v", b, err)
	}
}

func TestALinkWhereTheAWSCheckShouldBeIsNotBelieved(t *testing.T) {
	const now = int64(1_800_000_000)
	e, dir := newAWSEnv(t), staleAWS(t, now)
	replaceWithLink(t, e.state, strconv.FormatInt(now, 10)+" ok\n")
	if got := e.render(dir, now); got != "aws:?" || e.spawns != 1 {
		t.Errorf("got %q spawns=%d, want aws:? 1", got, e.spawns)
	}
}

// The aws CLI writes the login cache; a link is followed, a FIFO is not waited for.
func TestTheAWSLoginCacheFollowsALinkAndIsNotHeldByAFifo(t *testing.T) {
	const now = int64(1_800_000_000)
	dir := t.TempDir()
	entry := filepath.Join(dir, "session.json")

	replaceWithLink(t, entry, `{"idToken":"`+awsIDToken(now-60)+`"}`)
	e := newAWSEnv(t)
	if got := e.render(dir, now); got != "aws:✓" || e.spawns != 0 {
		t.Errorf("링크의 로그인 캐시: got %q spawns=%d, want aws:✓ 0", got, e.spawns)
	}

	replaceWithFifo(t, entry)
	e = newAWSEnv(t)
	var got string
	returnsInTime(t, entry, func() { got = e.render(dir, now) })
	if got != "aws:?" || e.spawns != 1 {
		t.Errorf("FIFO 로그인 캐시: got %q spawns=%d, want aws:? 1", got, e.spawns)
	}
}
