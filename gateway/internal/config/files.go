package config

// The files block: signed file URLs (FR-38, NFR-12, PLAN 5.3, D-061). Absent means the feature
// is off. The HMAC key comes from a key file the config names, or is random for this process.
// The config file itself never holds a key (NFR-14).

import (
	"bytes"
	"crypto/rand"
	"errors"
	"os"
	"path/filepath"
	"regexp"

	"agmente/gateway/internal/jsonv"
)

// Files is the validated files block.
type Files struct {
	Host       string
	TTLSeconds int64  // URL lifetime, at most 300 (NFR-12)
	MaxBytes   int64  // largest file served
	SecretFile string // "" when the key is random for this process
	Key        []byte // HMAC-SHA256 key for the URL tokens
}

const (
	defaultFileTTL      = 300
	maxFileTTL          = 300
	defaultFileMaxBytes = 20 * 1024 * 1024
	maxFileMaxBytes     = 1 << 30
	minFileKeyBytes     = 32
)

var hostNamePattern = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$`)

// validateFiles returns the files setting (nil when absent) and any errors.
func validateFiles(v *jsonv.Value) (*Files, []string) {
	if v.IsNull() {
		return nil, nil
	}
	if v.Kind != jsonv.Object {
		return nil, []string{"files must be an object"}
	}
	var errs []string
	f := &Files{TTLSeconds: defaultFileTTL, MaxBytes: defaultFileMaxBytes}

	host, ok := v.Get("host").StringValue()
	if !ok || !hostNamePattern.MatchString(host) {
		errs = append(errs, "files.host must be a host name in lowercase, such as files.example.com (no port, no scheme)")
	}
	f.Host = host

	if v.Get("key") != nil || v.Get("secret") != nil {
		errs = append(errs, "files must not hold a key: name a key file with files.secretFile (NFR-14)")
	}
	if t := v.Get("ttlSeconds"); !t.IsNull() {
		if n, ok := t.Int(); ok && n >= 1 && n <= maxFileTTL {
			f.TTLSeconds = n
		} else {
			errs = append(errs, "files.ttlSeconds must be an integer from 1 to 300 (NFR-12)")
		}
	}
	if m := v.Get("maxBytes"); !m.IsNull() {
		if n, ok := m.Int(); ok && n >= 1 && n <= maxFileMaxBytes {
			f.MaxBytes = n
		} else {
			errs = append(errs, "files.maxBytes must be an integer from 1 to 1073741824")
		}
	}
	if sf := v.Get("secretFile"); !sf.IsNull() {
		p, ok := sf.StringValue()
		if !ok || !filepath.IsAbs(p) {
			errs = append(errs, "files.secretFile must be an absolute path to a key file")
		} else if key, err := readKeyFile(p); err != nil {
			errs = append(errs, "files.secretFile: "+err.Error())
		} else {
			f.SecretFile = p
			f.Key = key
		}
	}
	if f.Key == nil && len(errs) == 0 {
		key := make([]byte, 32)
		if _, err := rand.Read(key); err != nil {
			return nil, append(errs, "cannot create the file URL key")
		}
		f.Key = key
	}
	if len(errs) > 0 {
		return nil, errs
	}
	return f, nil
}

// readKeyFile reads the HMAC key. The file must be regular, with no group or other permission
// bits, and hold at least 32 bytes. The error text never includes the key.
func readKeyFile(path string) ([]byte, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, errors.New("cannot read the key file")
	}
	if !info.Mode().IsRegular() {
		return nil, errors.New("the key file must be a regular file")
	}
	if info.Mode().Perm()&0o077 != 0 {
		return nil, errors.New("the key file must not be readable or writable by group or others (chmod 600)")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, errors.New("cannot read the key file")
	}
	key := bytes.TrimRight(data, "\r\n")
	if len(key) < minFileKeyBytes {
		return nil, errors.New("the key file must hold at least 32 bytes")
	}
	return key, nil
}
