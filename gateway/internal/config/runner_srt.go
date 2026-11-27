package config

// The srt runner block (D-122): the agent runs as a process under Anthropic sandbox-runtime, not in
// a container. The block names the `srt` command, the hosts the agent may reach, and the extra
// paths it may read.

import (
	"net"
	"path/filepath"
	"regexp"
	"slices"
	"strings"

	"acpcode/gateway/internal/jsonv"
)

const maxSRTDomains = 64

// srtDomainPattern is srt's allowedDomains grammar without IP literals: a host name, optionally
// with a leading `*.`, optionally with `:port`. A bare `*` is refused.
var srtDomainPattern = regexp.MustCompile(`^(\*\.)?[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*(:[0-9]{1,5})?$`)

// validateSRT reads the runner block of kind "srt". roots and stateDir are the agent-writable
// regions: the srt command must not lie inside them, or the sandboxed agent could rewrite it.
// specs are the parsed runners: each ends with its own allowedDomains and allowRead when it set
// them, else the shared lists of this block, and must have at least one domain (D-126).
func validateSRT(rv *jsonv.Value, roots []string, stateDir string, specs []agentSpec, add func(string, ...any)) Runner {
	r := Runner{Kind: "srt"}
	for _, key := range rv.Keys {
		switch key {
		case "kind", "srt", "allowedDomains", "allowRead", "weakerNetworkIsolation", "allowLocalBinding":
		default:
			add("runner.%s is not a known key for runner.kind \"srt\"", key)
		}
	}

	bin, ok := rv.Get("srt").StringValue()
	switch {
	case !ok || !filepath.IsAbs(bin):
		add("runner.srt must be an absolute path to the srt command (npm install -g @anthropic-ai/sandbox-runtime)")
	default:
		r.SRT = filepath.Clean(bin)
		regions := append([]string{stateDir}, roots...)
	refused:
		for _, p := range []string{r.SRT, resolved(r.SRT)} {
			for _, region := range regions {
				if region == "" {
					continue
				}
				// Compare with the region as written and with its links followed: /var is a link
				// to /private/var on a Mac, so one side alone misses a path given the other way.
				for _, reg := range []string{region, resolved(region)} {
					if Within(p, reg) {
						add("runner.srt must lie outside the project roots and the state folder: the agent can write there and could replace it")
						break refused
					}
				}
			}
		}
	}

	if dv := rv.Get("allowedDomains"); !dv.IsNull() {
		r.AllowedDomains = parseSRTDomains(dv, "runner", add)
	}
	r.AllowRead = parseSRTAllowRead(rv.Get("allowRead"), "runner", add)

	// Each runner takes its own lists when it set them, else the shared ones.
	sharedMissing := false
	for i := range specs {
		sp := &specs[i]
		if !sp.hasDomains {
			sp.AllowedDomains = slices.Clone(r.AllowedDomains)
			if rv.Get("allowedDomains").IsNull() {
				sharedMissing = true
			}
		}
		if !sp.hasRead {
			sp.AllowRead = slices.Clone(r.AllowRead)
		}
	}
	if sharedMissing {
		add("runner.allowedDomains must list 1 to %d hosts the agent may reach (Bob's own service at least), for example \"*.example.com\"; or give every runner its own allowedDomains", maxSRTDomains)
	}

	if wv := rv.Get("weakerNetworkIsolation"); !wv.IsNull() {
		if wv.Kind != jsonv.Bool {
			add("runner.weakerNetworkIsolation must be true or false")
		} else {
			r.WeakerNetworkIsolation = wv.B
		}
	}
	if lv := rv.Get("allowLocalBinding"); !lv.IsNull() {
		if lv.Kind != jsonv.Bool {
			add("runner.allowLocalBinding must be true or false")
		} else {
			r.AllowLocalBinding = lv.B
		}
	}
	return r
}

// parseSRTDomains reads an allowedDomains list: 1 to maxSRTDomains hosts, duplicates dropped. what
// names the owner in error messages ("runner" or "runners.<id>").
func parseSRTDomains(dv *jsonv.Value, what string, add func(string, ...any)) []string {
	if dv.IsNull() || dv.Kind != jsonv.Array || len(dv.Arr) == 0 || len(dv.Arr) > maxSRTDomains {
		add("%s.allowedDomains must list 1 to %d hosts the agent may reach (Bob's own service at least), for example \"*.example.com\"", what, maxSRTDomains)
		return nil
	}
	var out []string
	seen := map[string]bool{}
	for i, item := range dv.Arr {
		s, ok := item.StringValue()
		host, _, _ := strings.Cut(s, ":")
		if !ok || len(s) > 253 || !srtDomainPattern.MatchString(s) || net.ParseIP(strings.TrimPrefix(host, "*.")) != nil || allDigitsTLD(host) {
			add("%s.allowedDomains[%d] must be a lowercase host name, optionally \"*.\" first and \":port\" last", what, i)
			continue
		}
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}

// parseSRTAllowRead reads an allowRead list of absolute paths. Absent gives nil.
func parseSRTAllowRead(av *jsonv.Value, what string, add func(string, ...any)) []string {
	if av.IsNull() {
		return nil
	}
	if av.Kind != jsonv.Array {
		add("%s.allowRead must be a list of absolute paths", what)
		return nil
	}
	var out []string
	for i, item := range av.Arr {
		s, ok := item.StringValue()
		if !ok || !filepath.IsAbs(s) || s == "/" || strings.ContainsAny(s, "*?[]") {
			add("%s.allowRead[%d] must be an absolute path other than \"/\", with no glob characters", what, i)
			continue
		}
		out = append(out, filepath.Clean(s))
	}
	return out
}

// allDigitsTLD reports whether the last label is numeric, as in 10.0.0.1 or 1.2.3.4.5: srt reads
// such an entry as an address, and the gateway does not allow addresses here.
func allDigitsTLD(host string) bool {
	last := host[strings.LastIndex(host, ".")+1:]
	if last == "" {
		return false
	}
	for _, c := range last {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// resolved is path with symbolic links followed, or path itself when it cannot be resolved.
func resolved(path string) string {
	if p, err := filepath.EvalSymlinks(path); err == nil {
		return p
	}
	return path
}

// Within reports whether path is dir or lies inside it.
func Within(path, dir string) bool {
	rel, err := filepath.Rel(filepath.Clean(dir), filepath.Clean(path))
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}
