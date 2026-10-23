package statefile

import (
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

func TestWriteCreatesPrivateFileAndDirAndLeavesNoTemp(t *testing.T) {
	path := filepath.Join(t.TempDir(), "a", "b", "x.env")
	if err := Write(path, []byte("k=v\n")); err != nil {
		t.Fatalf("Write: %v", err)
	}
	if b, _ := os.ReadFile(path); string(b) != "k=v\n" {
		t.Fatalf("내용 = %q", b)
	}
	if info, _ := os.Stat(path); info.Mode().Perm() != 0o600 {
		t.Errorf("파일 mode = %v, want 0600", info.Mode().Perm())
	}
	if info, _ := os.Stat(filepath.Dir(path)); info.Mode().Perm() != 0o700 {
		t.Errorf("디렉터리 mode = %v, want 0700", info.Mode().Perm())
	}
	ents, _ := os.ReadDir(filepath.Dir(path))
	if len(ents) != 1 {
		t.Errorf("임시 파일이 남았다: %v", ents)
	}
}

func TestWriteReplacesAnExistingFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "x.env")
	Write(path, []byte("old"))
	if err := Write(path, []byte("new")); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(path); string(b) != "new" {
		t.Fatalf("교체되지 않았다: %q", b)
	}
}

func touch(t *testing.T, path string, age time.Duration) {
	t.Helper()
	if err := os.WriteFile(path, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	at := time.Now().Add(-age)
	if err := os.Chtimes(path, at, at); err != nil {
		t.Fatal(err)
	}
}

func TestPruneRemovesFilesOlderThanMaxAge(t *testing.T) {
	dir := t.TempDir()
	touch(t, filepath.Join(dir, "old.env"), 48*time.Hour)
	touch(t, filepath.Join(dir, "new.env"), time.Hour)
	Prune(dir, time.Now(), 24*time.Hour, 0)
	if _, err := os.Stat(filepath.Join(dir, "old.env")); !os.IsNotExist(err) {
		t.Error("기한이 지난 파일이 남았다")
	}
	if _, err := os.Stat(filepath.Join(dir, "new.env")); err != nil {
		t.Error("기한 안의 파일이 지워졌다")
	}
}

func TestPruneKeepsTheNewestMaxFiles(t *testing.T) {
	dir := t.TempDir()
	for i := 0; i < 5; i++ {
		touch(t, filepath.Join(dir, "f"+strconv.Itoa(i)), time.Duration(5-i)*time.Hour) // f4 is the newest
	}
	Prune(dir, time.Now(), 24*time.Hour, 3)
	ents, _ := os.ReadDir(dir)
	if len(ents) != 3 {
		t.Fatalf("남은 파일 %d개, want 3", len(ents))
	}
	for _, name := range []string{"f2", "f3", "f4"} {
		if _, err := os.Stat(filepath.Join(dir, name)); err != nil {
			t.Errorf("최신 파일 %s 가 지워졌다", name)
		}
	}
}

func TestPruneIgnoresSubdirectoriesAndMissingDir(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, "sub"), 0o700)
	Prune(dir, time.Now(), time.Nanosecond, 1)
	if _, err := os.Stat(filepath.Join(dir, "sub")); err != nil {
		t.Error("하위 디렉터리를 지웠다")
	}
	Prune(filepath.Join(dir, "missing"), time.Now(), time.Hour, 1) // must not panic
}
