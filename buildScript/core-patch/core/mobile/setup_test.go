package mobile

import (
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// restoreSetup saves the globals through the locked accessors and restores them
// at cleanup so this test cannot leak paths into the next one.
func restoreSetup(t *testing.T) {
	t.Helper()
	base, working, temp := setupPaths()
	debug := setupDebug()
	t.Cleanup(func() {
		setupMu.Lock()
		sBasePath, sWorkingPath, sTempPath, sDebug = base, working, temp, debug
		setupMu.Unlock()
	})
}

// A handler reading the setup snapshot must never observe a half-updated path
// trio: with two writers alternating complete pairs, every snapshot has to
// contain paths from one pair or the other, never a mix.
func TestSetupPathsSnapshotIsAtomic(t *testing.T) {
	restoreSetup(t)
	root, err := filepath.Abs(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}

	makePair := func(mark string) SetupOptions {
		dir := filepath.Join(root, mark)
		return SetupOptions{
			BasePath:    filepath.Join(dir, "base"),
			WorkingPath: filepath.Join(dir, "working"),
			TempPath:    filepath.Join(dir, "temp"),
		}
	}
	pairs := []SetupOptions{makePair("alpha"), makePair("bravo")}
	// Prime the globals before the reader starts: an uninitialised (empty)
	// snapshot is legitimate before the first Setup and not a torn pair.
	if err := Setup(&pairs[0]); err != nil {
		t.Fatal(err)
	}

	// Which pair a path belongs to is encoded in its parent directory name.
	markOf := func(path string) string {
		parent := filepath.Base(filepath.Dir(path))
		switch parent {
		case "alpha", "bravo":
			return parent
		}
		return "unknown:" + parent
	}

	const rounds = 200
	var wg sync.WaitGroup
	errCh := make(chan string, rounds)
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < rounds; i++ {
			if err := Setup(&pairs[i%len(pairs)]); err != nil {
				errCh <- err.Error()
				return
			}
		}
	}()
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < rounds; i++ {
			base, working, temp := setupPaths()
			mb, mw, mt := markOf(base), markOf(working), markOf(temp)
			if mb != mw || mb != mt || (mb != "alpha" && mb != "bravo") {
				errCh <- "torn setup snapshot: " + strings.Join([]string{mb, mw, mt}, "/")
				return
			}
		}
	}()
	wg.Wait()
	close(errCh)
	for message := range errCh {
		t.Fatal(message)
	}
}
