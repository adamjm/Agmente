package server

// The container user under rootless Podman (D-051). Skipped, with the reason, where Podman or the
// image is missing. Verified on a Mac Podman machine only; a Linux host is NOT VERIFIED (RESULTS).

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"acpcode/gateway/internal/config"
)

func podmanOrSkip(t *testing.T) (podman, image string) {
	t.Helper()
	podman, err := exec.LookPath("podman")
	if err != nil {
		t.Skip("skipped: podman is not installed")
	}
	image = os.Getenv("ACPCODE_TEST_IMAGE")
	if image == "" {
		image = "localhost/acpcode-bob:2.0.9"
	}
	if exec.Command(podman, "image", "exists", image).Run() != nil {
		t.Skipf("skipped: image %s is not available (set ACPCODE_TEST_IMAGE)", image)
	}
	return podman, image
}

func TestPodmanUserArgsDefaultsAndConfig(t *testing.T) {
	r := podmanRunner{cfg: &config.Config{}}
	if got := strings.Join(r.userArgs(), " "); got != "--userns=keep-id:uid=10001,gid=10001 --user 10001:10001" {
		t.Fatalf("default: %s", got)
	}
	r = podmanRunner{cfg: &config.Config{Runner: config.Runner{ContainerUID: 1234, ContainerGID: 4321}}}
	if got := strings.Join(r.userArgs(), " "); got != "--userns=keep-id:uid=1234,gid=4321 --user 1234:4321" {
		t.Fatalf("configured: %s", got)
	}
}

// The folders the gateway makes are 0700 and owned by the gateway user. With the user flags the
// container user can write the project home, the snapshot folder and the project folder, and what
// it writes belongs to the gateway user on the host. Without the flags it cannot (the control).
func TestPodmanContainerUserWritesOwnerOnlyFolders(t *testing.T) {
	podman, image := podmanOrSkip(t)
	s, p := gitTestServer(t)
	s.cfg.Runner = config.Runner{Kind: "podman", Image: image, Podman: podman}
	r := podmanRunner{cfg: s.cfg}
	home := s.projectHome(p.ID)
	snaps := filepath.Join(s.snapshotDir(p), "objects")
	for _, dir := range []string{p.Path, home, snaps} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(dir, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	script := "touch '" + filepath.Join(home, "h") + "' '" + filepath.Join(snaps, "o") + "' '" + filepath.Join(p.Path, "f") + "' && id -u"
	res, err := r.exec(context.Background(), p, home, []string{"/bin/sh", "-c", script}, nil, nil)
	if err != nil {
		t.Fatalf("the container user could not write the folders: %v", err)
	}
	if got := strings.TrimSpace(string(res.Out)); got != "10001" {
		t.Fatalf("container uid = %q", got)
	}
	for _, f := range []string{filepath.Join(home, "h"), filepath.Join(snaps, "o"), filepath.Join(p.Path, "f")} {
		info, err := os.Stat(f)
		if err != nil {
			t.Fatal(err)
		}
		if uid := info.Sys().(*syscall.Stat_t).Uid; int(uid) != os.Getuid() {
			t.Errorf("%s is owned by %d on the host, want the gateway user %d", f, uid, os.Getuid())
		}
	}
	for _, dir := range []string{p.Path, home, snaps} {
		if info, _ := os.Stat(dir); info.Mode().Perm() != 0o700 {
			t.Errorf("%s mode = %v: the flags must not need a looser mode", dir, info.Mode().Perm())
		}
	}

	// Control: the same run with no user flags is refused.
	args := []string{"run", "--rm", "--pull=never", "--network=none", "-v", home + ":" + home, "--entrypoint", "/bin/sh", image, "-c", "touch '" + filepath.Join(home, "denied") + "'"}
	if out, err := exec.Command(podman, args...).CombinedOutput(); err == nil {
		t.Fatalf("a container without the flags wrote a 0700 folder; this test proves nothing:\n%s", out)
	}
}
