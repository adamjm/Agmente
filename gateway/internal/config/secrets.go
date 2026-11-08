package config

// The agent secrets file (PLAN 4.2, FR-32, F-14). It holds NAME=value lines that the gateway passes
// to the agent's CLI environment at each agent start. The values never go in argv, never reach the
// audit log, and never appear in an error message: errors name a line number or a variable name only.

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"acpcode/gateway/internal/jsonv"
)

// Secret is one NAME=value entry of the secrets file.
type Secret struct {
	Name, Value string
}

// ParseSecrets reads NAME=value lines. Blank lines and lines starting with # are skipped. A value
// is what follows the first `=`, with surrounding white space removed. Names follow the
// environment-variable rule (envName). An empty value, a duplicate name or an empty file is refused.
func ParseSecrets(data []byte) ([]Secret, error) {
	var out []Secret
	seen := map[string]bool{}
	for i, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSuffix(line, "\r")
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		n := i + 1
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			return nil, fmt.Errorf("line %d must have the form NAME=value", n)
		}
		name := strings.TrimSpace(line[:eq])
		if !envName.MatchString(name) {
			return nil, fmt.Errorf("line %d: the name must match %s", n, envName.String())
		}
		value := strings.TrimSpace(line[eq+1:])
		if value == "" {
			return nil, fmt.Errorf("line %d (%s) has an empty value", n, name)
		}
		if seen[name] {
			return nil, fmt.Errorf("%s is set on more than one line", name)
		}
		seen[name] = true
		out = append(out, Secret{Name: name, Value: value})
	}
	if len(out) == 0 {
		return nil, errors.New("the file holds no NAME=value entries")
	}
	return out, nil
}

// ReadSecretsFile reads and parses the secrets file at path. The path must be absolute and name a
// regular file with no group or other permission bits (mode 0600 or stricter), as the key files do
// (files.go, D-055). The gateway reads it again at every agent start, so an edit takes effect then.
func ReadSecretsFile(path string) ([]Secret, error) {
	if !filepath.IsAbs(path) {
		return nil, errors.New("the secrets file path must be absolute")
	}
	info, err := os.Stat(path)
	if err != nil {
		return nil, fmt.Errorf("cannot read the secrets file: %s", errnoName(err))
	}
	if !info.Mode().IsRegular() {
		return nil, errors.New("the secrets file must be a regular file")
	}
	if info.Mode().Perm()&0o077 != 0 {
		return nil, errors.New("the secrets file must not be readable or writable by group or others (chmod 600)")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("cannot read the secrets file: %s", errnoName(err))
	}
	return ParseSecrets(data)
}

// validateSecrets checks agent.secretsFile and sorts its names into those the agent may receive
// (listed in envPassthrough) and those it ignores. HOME and PATH are never secrets: the gateway sets
// HOME, and the image sets PATH. ignored holds names only, so the caller can log them.
func validateSecrets(v *jsonv.Value, passthrough []string) (path string, allowed, ignored []string, errs []string) {
	if v.IsNull() {
		return "", nil, nil, nil
	}
	p, ok := v.StringValue()
	if !ok || !filepath.IsAbs(p) {
		return "", nil, nil, []string{"agent.secretsFile must be an absolute path to a NAME=value file"}
	}
	secrets, err := ReadSecretsFile(p)
	if err != nil {
		return "", nil, nil, []string{"agent.secretsFile: " + err.Error()}
	}
	listed := map[string]bool{}
	for _, name := range passthrough {
		listed[name] = true
	}
	for _, s := range secrets {
		switch {
		case s.Name == "HOME" || s.Name == "PATH":
			errs = append(errs, fmt.Sprintf("agent.secretsFile must not set %s", s.Name))
		case listed[s.Name]:
			allowed = append(allowed, s.Name)
		default:
			ignored = append(ignored, s.Name)
		}
	}
	if len(errs) > 0 {
		return "", nil, nil, errs
	}
	return p, allowed, ignored, nil
}
