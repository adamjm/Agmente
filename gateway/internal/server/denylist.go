package server

// The secret deny-list (FR-30, D-035) and a project's additions to it (D-050). The effective list
// of a project is the built-in list plus its own entries: no code path takes an entry away.

import (
	"fmt"
	"path"
	"strings"
	"unicode/utf8"
)

const (
	maxDenyPaths   = 32
	maxDenyPathLen = 100
)

// validateDenyPaths checks a project's denyPaths and returns them in the form that is stored.
// An entry is a glob of ASCII letters, digits, space and . _ - / * only, so Go's matcher and git's
// pathspec glob agree on it (no [], ?, ** or \, which differ between them on multi-byte names).
// An entry with no "/" is matched against every path component, as the built-in list is; an entry
// with a "/" is matched against a leading part of the path, from the project root. Entries are
// relative: no leading "/", no empty, "." or ".." component, no trailing "/".
func validateDenyPaths(in []string) ([]string, error) {
	if len(in) > maxDenyPaths {
		return nil, fmt.Errorf("denyPaths holds at most %d entries", maxDenyPaths)
	}
	seen := map[string]bool{}
	out := []string{}
	for _, e := range in {
		if e == "" || len(e) > maxDenyPathLen || !utf8.ValidString(e) {
			return nil, fmt.Errorf("each denyPaths entry must be 1 to %d characters", maxDenyPathLen)
		}
		for i := 0; i < len(e); i++ {
			c := e[i]
			ok := c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.IndexByte(" ._-/*", c) >= 0
			if !ok {
				return nil, fmt.Errorf("a denyPaths entry may use only letters, digits, space and . _ - / *")
			}
		}
		if strings.Contains(e, "**") {
			return nil, fmt.Errorf("a denyPaths entry may not contain \"**\"")
		}
		if strings.HasPrefix(e, "/") {
			return nil, fmt.Errorf("a denyPaths entry must be relative to the project, not an absolute path")
		}
		for _, part := range strings.Split(e, "/") {
			switch part {
			case "":
				return nil, fmt.Errorf("a denyPaths entry may not have an empty component or a trailing \"/\"")
			case ".", "..":
				return nil, fmt.Errorf("a denyPaths entry may not contain \".\" or \"..\"")
			}
		}
		if strings.TrimSpace(e) != e {
			return nil, fmt.Errorf("a denyPaths entry may not start or end with a space")
		}
		key := strings.ToLower(e)
		if !seen[key] {
			seen[key] = true
			out = append(out, e)
		}
	}
	return out, nil
}

// isSecretFor reports whether a project-relative path is on the built-in list or on the project's.
func isSecretFor(extra []string, p string) bool {
	if isSecretPath(p) {
		return true
	}
	parts := strings.Split(p, "/")
	for _, pat := range extra {
		pat = strings.ToLower(pat)
		if !strings.Contains(pat, "/") {
			for _, part := range parts {
				if ok, _ := path.Match(pat, strings.ToLower(part)); ok {
					return true
				}
			}
			continue
		}
		n := strings.Count(pat, "/") + 1 // the pattern covers a leading part of this many components
		if len(parts) >= n {
			if ok, _ := path.Match(pat, strings.ToLower(strings.Join(parts[:n], "/"))); ok {
				return true
			}
		}
	}
	return false
}

// secretExcludesFor are the pathspecs that make git leave the built-in list and the project's
// entries out of a whole-tree diff.
func secretExcludesFor(extra []string) []string {
	out := secretExcludes()
	for _, pat := range extra {
		if strings.Contains(pat, "/") { // anchored at the project root
			out = append(out, ":(exclude,glob,icase)"+pat, ":(exclude,glob,icase)"+pat+"/**")
		} else {
			out = append(out, ":(exclude,glob,icase)**/"+pat, ":(exclude,glob,icase)**/"+pat+"/**")
		}
	}
	return out
}
