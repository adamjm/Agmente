package config

// The git block (D-105): the hosts that a git remote and a git credential may name. Only the
// host is configured; a URL, a token or a credential never goes in the config file (NFR-14).

import (
	"regexp"
	"strings"

	"acpcode/gateway/internal/jsonv"
)

// DefaultGitHosts is the allow-list when the config has no git block.
var DefaultGitHosts = []string{"github.com"}

var gitHostPattern = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$`)

// validateGit reads the optional git block: {"hosts": ["github.com", ...]}. Each host is a lowercase
// host name with no scheme, path, port or user. Anything else in the block is refused.
func validateGit(v *jsonv.Value, add func(string, ...any)) []string {
	if v.IsNull() {
		return append([]string(nil), DefaultGitHosts...)
	}
	if v.Kind != jsonv.Object {
		add("git must be an object")
		return nil
	}
	for _, key := range v.Keys {
		if key != "hosts" {
			add("git.%s is not a known key", key)
		}
	}
	hv := v.Get("hosts")
	if hv.IsNull() {
		return append([]string(nil), DefaultGitHosts...)
	}
	if hv.Kind != jsonv.Array || len(hv.Arr) == 0 || len(hv.Arr) > 16 {
		add("git.hosts must be a list of 1 to 16 host names")
		return nil
	}
	var hosts []string
	seen := map[string]bool{}
	for i, item := range hv.Arr {
		host, ok := item.StringValue()
		if !ok || len(host) > 253 || !gitHostPattern.MatchString(host) || strings.Contains(host, "..") {
			add("git.hosts[%d] must be a lowercase host name such as \"github.com\" (no scheme, port, path or user)", i)
			continue
		}
		if !seen[host] {
			seen[host] = true
			hosts = append(hosts, host)
		}
	}
	return hosts
}
