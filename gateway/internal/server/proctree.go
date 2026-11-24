package server

// The process tree of a sandboxed agent (srt runner, D-122). Bob starts some shell commands in a
// new process group, so signalling the agent's group misses them. The tree is read from ps before
// the signal and every member is signalled too.

import (
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
)

// treeMember is a process with its start time, so a pid that was reused is not signalled.
type treeMember struct {
	pid   int
	start string
}

// psRow is one line of `ps -axo pid=,ppid=,lstart=`.
type psRow struct {
	pid, ppid int
	start     string
}

// listProcesses reads every process. lstart is five fields ("Sat Nov 22 20:56:55 2026").
func listProcesses() []psRow {
	out, err := exec.Command("/bin/ps", "-axo", "pid=,ppid=,lstart=").Output()
	if err != nil {
		return nil
	}
	var rows []psRow
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 7 {
			continue
		}
		pid, err1 := strconv.Atoi(f[0])
		ppid, err2 := strconv.Atoi(f[1])
		if err1 != nil || err2 != nil {
			continue
		}
		rows = append(rows, psRow{pid, ppid, strings.Join(f[2:7], " ")})
	}
	return rows
}

// descendantsOf returns every process below root in rows.
func descendantsOf(rows []psRow, root int) []treeMember {
	kids := map[int][]psRow{}
	for _, r := range rows {
		kids[r.ppid] = append(kids[r.ppid], r)
	}
	var out []treeMember
	todo := []int{root}
	for len(todo) > 0 {
		p := todo[len(todo)-1]
		todo = todo[:len(todo)-1]
		for _, k := range kids[p] {
			out = append(out, treeMember{k.pid, k.start})
			todo = append(todo, k.pid)
		}
	}
	return out
}

// signalTree sends sig to each member that is still the same process.
func signalTree(members []treeMember, sig syscall.Signal) {
	if len(members) == 0 {
		return
	}
	now := map[int]string{}
	for _, r := range listProcesses() {
		now[r.pid] = r.start
	}
	for _, m := range members {
		if start, ok := now[m.pid]; ok && start == m.start {
			_ = syscall.Kill(m.pid, sig)
		}
	}
}

// orphansIn returns the processes of this user whose parent is launchd (pid 1) and whose working
// directory is inside any of dirs. After a hard kill of the gateway these are the commands the
// sandboxed agent left behind, which no signal to a group or a tree can reach any more.
func orphansIn(dirs []string) []treeMember {
	out, err := exec.Command("/usr/sbin/lsof", "-a", "-d", "cwd", "-u", strconv.Itoa(os.Getuid()), "-Fpn").Output()
	if err != nil && len(out) == 0 {
		return nil
	}
	inside := func(cwd string) bool {
		for _, d := range dirs {
			if cwd == d || strings.HasPrefix(cwd, d+"/") {
				return true
			}
		}
		return false
	}
	want := map[int]bool{}
	pid := 0
	for _, line := range strings.Split(string(out), "\n") {
		switch {
		case strings.HasPrefix(line, "p"):
			pid, _ = strconv.Atoi(line[1:])
		case strings.HasPrefix(line, "n") && pid > 0 && inside(line[1:]):
			want[pid] = true
		}
	}
	var res []treeMember
	for _, r := range listProcesses() {
		if want[r.pid] && r.ppid == 1 && r.pid != os.Getpid() {
			res = append(res, treeMember{r.pid, r.start})
		}
	}
	return res
}

// reapOrphans kills what orphansIn finds, and the processes below each, and reports how many.
func reapOrphans(dirs []string) int {
	found := orphansIn(dirs)
	if len(found) == 0 {
		return 0
	}
	all := append([]treeMember(nil), found...)
	rows := listProcesses()
	for _, f := range found {
		all = append(all, descendantsOf(rows, f.pid)...)
	}
	signalTree(all, syscall.SIGKILL)
	return len(found)
}
