package server

// The secret deny-list (FR-30, D-035) and a project's additions to it (D-050, D-066). The effective
// list of a project is the built-in list plus its own entries: no code path takes an entry away.
// It also holds the watcher's skip list (D-065), which only adds to the built-in folders.

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
	return validatePathList("denyPaths", in, true)
}

// validateWatchSkip checks a project's watchSkip (D-065): the rules of denyPaths without "*", so an
// entry is a literal relative path of folder names.
func validateWatchSkip(in []string) ([]string, error) {
	return validatePathList("watchSkip", in, false)
}

// validatePathList is the one validator for both lists (D-066). field names the list in every
// error. globs allows "*" in an entry; without it an entry is a literal path.
func validatePathList(field string, in []string, globs bool) ([]string, error) {
	if len(in) > maxDenyPaths {
		return nil, fmt.Errorf("%s holds at most %d entries", field, maxDenyPaths)
	}
	charset := "letters, digits, space and . _ - /"
	extra := ""
	if globs {
		extra = "*"
		charset = "letters, digits, space and . _ - / *"
	}
	seen := map[string]bool{}
	out := []string{}
	for _, e := range in {
		if e == "" || len(e) > maxDenyPathLen || !utf8.ValidString(e) {
			return nil, fmt.Errorf("each %s entry must be 1 to %d characters", field, maxDenyPathLen)
		}
		for i := 0; i < len(e); i++ {
			c := e[i]
			ok := c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.IndexByte(" ._-/"+extra, c) >= 0
			if !ok {
				return nil, fmt.Errorf("a %s entry may use only %s", field, charset)
			}
		}
		if strings.Contains(e, "**") {
			return nil, fmt.Errorf("a %s entry may not contain \"**\"", field)
		}
		if strings.HasPrefix(e, "/") {
			return nil, fmt.Errorf("a %s entry must be relative to the project, not an absolute path", field)
		}
		for _, part := range strings.Split(e, "/") {
			switch part {
			case "":
				return nil, fmt.Errorf("a %s entry may not have an empty component or a trailing \"/\"", field)
			case ".", "..":
				return nil, fmt.Errorf("a %s entry may not contain \".\" or \"..\"", field)
			}
		}
		if strings.TrimSpace(e) != e {
			return nil, fmt.Errorf("a %s entry may not start or end with a space", field)
		}
		key := strings.ToLower(e)
		if !seen[key] {
			seen[key] = true
			out = append(out, e)
		}
	}
	return out, nil
}

// mergeEntries adds validated entries to a stored list (D-066): case-insensitive, the spelling
// already stored is kept, no duplicates. It never removes an entry. The total is capped at 32.
func mergeEntries(field string, current, add []string) ([]string, error) {
	out := append([]string{}, current...)
	seen := map[string]bool{}
	for _, e := range out {
		seen[strings.ToLower(e)] = true
	}
	for _, e := range add {
		if !seen[strings.ToLower(e)] {
			seen[strings.ToLower(e)] = true
			out = append(out, e)
		}
	}
	if len(out) > maxDenyPaths {
		return nil, fmt.Errorf("%s holds at most %d entries", field, maxDenyPaths)
	}
	return out, nil
}

// watchSkipper says which folders the git watcher leaves out (D-065): the built-in names and a
// project's watchSkip. A bare name skips a folder of that name at any depth; an entry with a "/"
// skips the folder at that path from the project root. Matching is exact.
type watchSkipper struct {
	names map[string]bool
	paths map[string]bool
}

func newWatchSkipper(extra []string) watchSkipper {
	k := watchSkipper{names: map[string]bool{}, paths: map[string]bool{}}
	for _, e := range extra {
		if strings.Contains(e, "/") {
			k.paths[e] = true
		} else {
			k.names[e] = true
		}
	}
	return k
}

// skips reports whether the folder called name, at rel (slash-separated, from the root), is left out.
func (k watchSkipper) skips(name, rel string) bool {
	return skipDirs[name] || k.names[name] || k.paths[rel]
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
