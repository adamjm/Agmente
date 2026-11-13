package server

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The name rule for an upload: one component, folder-name bytes, an allowed type, not reserved, not a
// secret. Each refusal has its own reason, so the audit line says why.
func TestUploadNameRules(t *testing.T) {
	long := strings.Repeat("a", 60) + ".png" // 64 bytes: allowed
	tooLong := strings.Repeat("a", 61) + ".png"
	cases := []struct {
		name, want string
		deny       []string
	}{
		{"photo.png", "", nil},
		{"a b_c-1.txt", "", nil},
		{long, "", nil},
		{tooLong, uploadRefusedName, nil},
		{"", uploadRefusedName, nil},
		{".env", uploadRefusedName, nil},
		{".hidden.txt", uploadRefusedName, nil},
		{" lead.txt", uploadRefusedName, nil},
		{"trail .txt", "", nil}, // a space inside is allowed; only the ends are checked
		{"trail. ", uploadRefusedName, nil},
		{"a/b.txt", uploadRefusedName, nil},
		{"../x.txt", uploadRefusedName, nil},
		{"a\x00.txt", uploadRefusedName, nil},
		{"a\n.txt", uploadRefusedName, nil},
		{"Résumé.pdf", uploadRefusedName, nil}, // ASCII only (D-091)
		{"main.swift", uploadRefusedType, nil},
		{"run.sh", uploadRefusedType, nil},
		{"page.html", uploadRefusedType, nil},
		{"noext", uploadRefusedType, nil},
		{"AGENTS.md", uploadRefusedReserved, nil},
		{"agents.md", uploadRefusedReserved, nil},
		{"CLAUDE.md", uploadRefusedReserved, nil},
		{"opencode.json", uploadRefusedReserved, nil},
		{"api-secret.json", uploadRefusedSecret, nil},
		{"notes.txt", uploadRefusedSecret, []string{"notes.txt"}}, // the project's own deny-list
	}
	for _, c := range cases {
		if got := uploadNameReason(c.name, c.deny); got != c.want {
			t.Errorf("uploadNameReason(%q) = %q, want %q", c.name, got, c.want)
		}
	}
}

// stat's name rule is the syntax part only, so it can report a name that the upload would refuse as
// existing, but it never hashes one of those.
func TestUploadSyntaxRules(t *testing.T) {
	for name, want := range map[string]string{
		"AGENTS.md": "", "photo.png": "", "x": "", "main.swift": "", ".env": uploadRefusedName, "a/b": uploadRefusedName, "": uploadRefusedName,
	} {
		if got := uploadSyntaxReason(name); got != want {
			t.Errorf("uploadSyntaxReason(%q) = %q, want %q", name, got, want)
		}
	}
}

// The encoded cap is the length of maxUploadBytes in base64: 4 * ceil(n/3).
func TestUploadEncodedCapMatchesTheRawCap(t *testing.T) {
	if maxUploadEncoded != 11184812 {
		t.Fatalf("maxUploadEncoded = %d, want 11184812 (8 MiB in base64)", maxUploadEncoded)
	}
}

// The write goes through a temporary name and a hard link, so an existing name is never replaced, even
// when it is a dangling symbolic link (Lstat sees it, Link refuses it).
func TestWriteUploadNoClobberNeverReplacesAName(t *testing.T) {
	dir := t.TempDir()
	root, err := os.OpenRoot(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()

	if err := os.WriteFile(filepath.Join(dir, "kept.txt"), []byte("original"), 0o600); err != nil {
		t.Fatal(err)
	}
	err = writeUploadNoClobber(root, "kept.txt", []byte("new"))
	if !errors.Is(err, fs.ErrExist) {
		t.Fatalf("writeUploadNoClobber over a file = %v, want ErrExist", err)
	}
	if got, _ := os.ReadFile(filepath.Join(dir, "kept.txt")); string(got) != "original" {
		t.Fatalf("the existing file was changed to %q", got)
	}

	// A dangling symbolic link at the name: Lstat sees it, and Link must refuse rather than follow it.
	if err := os.Symlink(filepath.Join(dir, "nowhere"), filepath.Join(dir, "link.txt")); err != nil {
		t.Fatal(err)
	}
	if err := writeUploadNoClobber(root, "link.txt", []byte("new")); !errors.Is(err, fs.ErrExist) {
		t.Fatalf("writeUploadNoClobber over a dangling link = %v, want ErrExist", err)
	}
	if _, err := os.Lstat(filepath.Join(dir, "nowhere")); !errors.Is(err, fs.ErrNotExist) {
		t.Fatal("the link target was created through the link")
	}

	// Nothing is left behind: no temporary name remains after a refusal.
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".upload") {
			t.Fatalf("a temporary file was left behind: %s", e.Name())
		}
	}
}

// A new name gets the bytes at mode 0644, and the temporary name is gone afterwards.
func TestWriteUploadWritesTheBytesAtMode0644(t *testing.T) {
	dir := t.TempDir()
	root, err := os.OpenRoot(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	if err := writeUploadNoClobber(root, "fresh.png", []byte{0x89, 'P', 'N', 'G'}); err != nil {
		t.Fatalf("write: %v", err)
	}
	got, err := os.ReadFile(filepath.Join(dir, "fresh.png"))
	if err != nil || string(got) != "\x89PNG" {
		t.Fatalf("content = %q, %v", got, err)
	}
	info, _ := os.Stat(filepath.Join(dir, "fresh.png"))
	if info.Mode().Perm() != 0o644 {
		t.Fatalf("mode = %o, want 644", info.Mode().Perm())
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 1 {
		t.Fatalf("entries = %d, want only the file", len(entries))
	}
}

// One upload per project at a time: a second take gets false until the first releases.
func TestUploadLockAllowsOneUploadPerProject(t *testing.T) {
	var u uploadLocks
	if !u.take("p1") {
		t.Fatal("first take refused")
	}
	if u.take("p1") {
		t.Fatal("second take on the same project allowed")
	}
	if !u.take("p2") {
		t.Fatal("another project refused")
	}
	u.release("p1")
	if !u.take("p1") {
		t.Fatal("take after release refused")
	}
}
