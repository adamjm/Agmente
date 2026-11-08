package server

import (
	"context"
	"os/exec"

	"acpcode/gateway/internal/config"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestTakeSnapshotOfASmallRepo(t *testing.T) {
	s, p := gitTestServer(t)
	mustGit(t, p.Path, "init", "-q")
	if err := os.WriteFile(filepath.Join(p.Path, "a.txt"), []byte("one\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	mustGit(t, p.Path, "add", ".")
	mustGit(t, p.Path, "commit", "-q", "-m", "one")
	tree, err := s.takeSnapshot(context.Background(), p)
	if err != nil {
		var ee *gitExitError
		if errors.As(err, &ee) {
			t.Fatalf("git failed (%d): %s", ee.Code, ee.Stderr)
		}
		t.Fatal(err)
	}
	if !treeID.MatchString(tree) {
		t.Fatalf("tree %q", tree)
	}
}

// T-27 for the snapshot, under real Podman: a repository whose clean filter is required (so a git
// that ran it would fail, as the TestCleanFilter test shows) still snapshots, and the marker is
// nowhere. Skipped, with the reason, where Podman or the image is missing.
func TestSnapshotRunsNoFilterUnderPodman(t *testing.T) {
	podman, err := exec.LookPath("podman")
	if err != nil {
		t.Skip("skipped: podman is not installed")
	}
	image := os.Getenv("ACPCODE_TEST_IMAGE")
	if image == "" {
		image = "localhost/acpcode-bob:2.0.9"
	}
	if exec.Command(podman, "image", "exists", image).Run() != nil {
		t.Skipf("skipped: image %s is not available (set ACPCODE_TEST_IMAGE)", image)
	}
	s, p := gitTestServer(t)
	s.cfg.Runner = config.Runner{Kind: "podman", Image: image, Podman: podman}
	s.runner = podmanRunner{cfg: s.cfg}
	// Owner-only folders, as the gateway makes them: the container user reaches them through
	// `--userns=keep-id` (D-051), not through open modes.
	for _, dir := range []string{p.Path, s.projectHome(p.ID)} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(dir, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	markers := t.TempDir()
	mustGit(t, p.Path, "init", "-q")
	_ = os.WriteFile(filepath.Join(p.Path, ".gitattributes"), []byte("*.txt filter=evil\n"), 0o644)
	_ = os.WriteFile(filepath.Join(p.Path, "a.txt"), []byte("one\n"), 0o644)
	_ = os.WriteFile(filepath.Join(p.Path, "b.txt"), []byte("two\n"), 0o644)
	mustGit(t, p.Path, "add", ".")
	mustGit(t, p.Path, "commit", "-q", "-m", "one")
	mustGit(t, p.Path, "config", "filter.evil.clean", "touch "+filepath.Join(markers, "ran")+" /tmp/acpcode-marker; false")
	mustGit(t, p.Path, "config", "filter.evil.required", "true")
	_ = os.WriteFile(filepath.Join(p.Path, "a.txt"), []byte("TWO\n"), 0o644)

	tree, err := s.takeSnapshot(context.Background(), p)
	if err != nil {
		var ee *gitExitError
		if errors.As(err, &ee) {
			t.Fatalf("snapshot failed (%d): %s", ee.Code, ee.Stderr)
		}
		t.Fatal(err)
	}
	if !treeID.MatchString(tree) {
		t.Fatalf("tree %q", tree)
	}
	if _, err := os.Stat(filepath.Join(markers, "ran")); err == nil {
		t.Fatal("a filter ran on the host")
	}
}
