package server

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestDescendantsOfWalksTheWholeTree(t *testing.T) {
	rows := []psRow{{2, 1, "a"}, {3, 2, "b"}, {4, 3, "c"}, {5, 1, "d"}, {6, 2, "e"}}
	got := map[int]bool{}
	for _, m := range descendantsOf(rows, 2) {
		got[m.pid] = true
	}
	for _, want := range []int{3, 4, 6} {
		if !got[want] {
			t.Errorf("descendant %d missing: %v", want, got)
		}
	}
	if got[5] || got[2] {
		t.Errorf("a process outside the tree, or the root, is listed: %v", got)
	}
}

func TestSignalTreeSkipsAReusedPid(t *testing.T) {
	cmd := exec.Command("sleep", "30")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = cmd.Process.Kill(); _, _ = cmd.Process.Wait() }()
	signalTree([]treeMember{{cmd.Process.Pid, "Mon Jan  1 00:00:00 1990"}}, syscall.SIGKILL)
	time.Sleep(100 * time.Millisecond)
	if syscall.Kill(cmd.Process.Pid, 0) != nil {
		t.Fatal("a process with another start time was signalled")
	}
	for _, r := range listProcesses() {
		if r.pid == cmd.Process.Pid {
			signalTree([]treeMember{{r.pid, r.start}}, syscall.SIGKILL)
		}
	}
	done := make(chan struct{})
	go func() { _, _ = cmd.Process.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("the matching process was not signalled")
	}
}

// A command detached from its parent (reparented to launchd) with its working directory in the
// project is found and killed; one in another directory is left alone.
func TestReapOrphansKillsOnlyThoseInTheProject(t *testing.T) {
	root, _ := filepath.EvalSymlinks(t.TempDir())
	mine, other := filepath.Join(root, "mine"), filepath.Join(root, "other")
	for _, d := range []string{mine, other} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	spawn := func(dir string) int {
		cmd := exec.Command("/bin/sh", "-c", "sleep 60 >/dev/null 2>&1 & echo $!")
		cmd.Dir = dir
		out, err := cmd.Output()
		if err != nil {
			t.Fatal(err)
		}
		pid, err := strconv.Atoi(strings.TrimSpace(string(out)))
		if err != nil {
			t.Fatalf("pid %q", out)
		}
		return pid
	}
	inside, outside := spawn(mine), spawn(other)
	defer func() { _ = syscall.Kill(inside, syscall.SIGKILL); _ = syscall.Kill(outside, syscall.SIGKILL) }()
	time.Sleep(300 * time.Millisecond) // the shell exits; launchd adopts the sleeps
	if n := reapOrphans([]string{mine}); n != 1 {
		t.Fatalf("reaped %d, want 1", n)
	}
	deadline := time.Now().Add(3 * time.Second)
	for syscall.Kill(inside, 0) == nil && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	if syscall.Kill(inside, 0) == nil {
		t.Error("the orphan in the project is alive")
	}
	if syscall.Kill(outside, 0) != nil {
		t.Error("an orphan in another directory was killed")
	}
}
