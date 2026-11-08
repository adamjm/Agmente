package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"acpcode/gateway/internal/jsonv"
)

func parseFiles(t *testing.T, src string) (*Files, []string) {
	t.Helper()
	v, err := jsonv.Parse([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	return validateFiles(v)
}

func TestFilesAbsentIsOff(t *testing.T) {
	f, errs := parseFiles(t, `null`)
	if f != nil || len(errs) != 0 {
		t.Fatalf("null files: %+v %v", f, errs)
	}
}

func TestFilesDefaultsAndRandomKey(t *testing.T) {
	f, errs := parseFiles(t, `{"host":"files.example.com"}`)
	if len(errs) != 0 {
		t.Fatal(errs)
	}
	if f.TTLSeconds != 300 || f.MaxBytes != 20*1024*1024 || len(f.Key) != 32 || f.SecretFile != "" {
		t.Fatalf("defaults: %+v", f)
	}
}

func TestFilesRefusesBadValues(t *testing.T) {
	cases := map[string]string{
		"uppercase host":  `{"host":"Files.example.com"}`,
		"host with port":  `{"host":"files.example.com:443"}`,
		"no host":         `{}`,
		"ttl over 300":    `{"host":"f.test","ttlSeconds":301}`,
		"ttl zero":        `{"host":"f.test","ttlSeconds":0}`,
		"key inline":      `{"host":"f.test","key":"abc"}`,
		"secret inline":   `{"host":"f.test","secret":"abc"}`,
		"relative key":    `{"host":"f.test","secretFile":"key"}`,
		"missing keyfile": `{"host":"f.test","secretFile":"/nonexistent/acpcode-key"}`,
	}
	for name, src := range cases {
		if f, errs := parseFiles(t, src); f != nil || len(errs) == 0 {
			t.Errorf("%s: accepted: %+v", name, f)
		}
	}
}

func TestKeyFileNeedsOwnerOnlyPermissions(t *testing.T) {
	dir := t.TempDir()
	key := filepath.Join(dir, "key")
	secret := strings.Repeat("k", 32)
	if err := os.WriteFile(key, []byte(secret+"\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(key, 0o640); err != nil {
		t.Fatal(err)
	}
	f, errs := parseFiles(t, `{"host":"f.test","secretFile":"`+key+`"}`)
	if f != nil || len(errs) == 0 || strings.Contains(strings.Join(errs, " "), secret) {
		t.Fatalf("group-readable key accepted or leaked: %v", errs)
	}
	if err := os.Chmod(key, 0o600); err != nil {
		t.Fatal(err)
	}
	f, errs = parseFiles(t, `{"host":"f.test","secretFile":"`+key+`"}`)
	if len(errs) != 0 || string(f.Key) != secret || f.SecretFile != key {
		t.Fatalf("0600 key: %v %+v", errs, f)
	}
}

func TestKeyFileNeedsThirtyTwoBytes(t *testing.T) {
	key := filepath.Join(t.TempDir(), "short")
	if err := os.WriteFile(key, []byte("short"), 0o600); err != nil {
		t.Fatal(err)
	}
	if f, errs := parseFiles(t, `{"host":"f.test","secretFile":"`+key+`"}`); f != nil || len(errs) == 0 {
		t.Fatal("a short key was accepted")
	}
}
