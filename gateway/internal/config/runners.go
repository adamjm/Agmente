package config

import (
	"regexp"

	"acpcode/gateway/internal/jsonv"
)

// AgentRunner is one agent the gateway can run for a project (multi-runner). Each has its own
// command, the environment names it may receive, and the image that runs it. The Runner block
// (kind, container CLI, DNS, container user) is shared by all of them.
type AgentRunner struct {
	ID             string
	Name           string
	Command        []string
	EnvPassthrough []string
	// Image is the project image for the podman and apple kinds. Empty for the host kind.
	Image string
}

// agentIDPattern is the rule for a runner id. It goes in URLs-free protocol fields and in container
// names only through the project id, so it stays short and lower case.
var agentIDPattern = regexp.MustCompile(`^[a-z][a-z0-9-]{0,31}$`)

// Agent returns the runner with this id. "" means the default runner.
func (c *Config) Agent(id string) (AgentRunner, bool) {
	if id == "" {
		id = c.DefaultRunner
	}
	for _, r := range c.Runners {
		if r.ID == id {
			return r, true
		}
	}
	return AgentRunner{}, false
}

// agentSpec is one parsed runner before the runner kind is known: the image is checked after
// the kind is read, because only the podman and apple kinds need one.
type agentSpec struct {
	AgentRunner
	imageRaw *jsonv.Value
}

// agentParse is the agent part of the config: the runners in config order, the default id, and
// the secrets file (single-agent form only).
type agentParse struct {
	specs          []agentSpec
	defaultRunner  string
	runnersForm    bool
	secretsFile    string
	secretNames    []string
	secretsIgnored []string
}

func (a agentParse) runners() []AgentRunner {
	out := make([]AgentRunner, 0, len(a.specs))
	for _, sp := range a.specs {
		out = append(out, sp.AgentRunner)
	}
	return out
}

// imageLabel names the image setting of one runner in error messages.
func (a agentParse) imageLabel(id string) string {
	if !a.runnersForm {
		return "runner.image"
	}
	return "runners." + id + ".image"
}

// parseAgents reads the runners map (multi-runner) or, when it is absent, the single agent block,
// which becomes one runner with id "default". The two forms cannot be mixed.
func parseAgents(raw *jsonv.Value, add func(string, ...any)) agentParse {
	rs := raw.Get("runners")
	if rs.IsNull() {
		return parseSingleAgent(raw, add)
	}
	out := agentParse{runnersForm: true}
	if !raw.Get("agent").IsNull() {
		add("use either runners or agent, not both: move the agent block into runners")
	}
	if !raw.Get("runner").Get("image").IsNull() {
		add("runner.image moves into each runners entry as image")
	}
	if rs.Kind != jsonv.Object || len(rs.Keys) == 0 {
		add("runners must be an object with at least one agent")
		return out
	}
	for _, id := range rs.Keys {
		if !agentIDPattern.MatchString(id) {
			add("runners id \"%s\" must match ^[a-z][a-z0-9-]{0,31}$", id)
			continue
		}
		entry := rs.Obj[id]
		what := "runners." + id
		if entry == nil || entry.Kind != jsonv.Object {
			add("%s must be an object", what)
			continue
		}
		if !entry.Get("secretsFile").IsNull() {
			add("%s.secretsFile is not supported with runners; the agent secrets file is only read in the single-agent form", what)
		}
		name := id
		if n := entry.Get("name"); !n.IsNull() {
			s, ok := n.StringValue()
			if !ok || s == "" || len(s) > 64 {
				add("%s.name must be a non-empty string of at most 64 characters", what)
			} else {
				name = s
			}
		}
		command := parseCommand(entry.Get("command"), what, add)
		env := parseEnv(entry.Get("envPassthrough"), what, add)
		out.specs = append(out.specs, agentSpec{
			AgentRunner: AgentRunner{ID: id, Name: name, Command: command, EnvPassthrough: env},
			imageRaw:    entry.Get("image"),
		})
	}
	def := raw.Get("defaultRunner")
	switch {
	case def.IsNull() && len(out.specs) == 1:
		out.defaultRunner = out.specs[0].ID
	case def.IsNull():
		add("defaultRunner is required when runners lists more than one agent")
	default:
		s, ok := def.StringValue()
		found := false
		for _, sp := range out.specs {
			if ok && sp.ID == s {
				found = true
			}
		}
		if !found {
			add("defaultRunner must be the id of one runner in runners")
		} else {
			out.defaultRunner = s
		}
	}
	return out
}

// parseSingleAgent reads the agent block of the single-agent form, the same as before runners.
// It becomes one runner with id "default", which is also the default.
func parseSingleAgent(raw *jsonv.Value, add func(string, ...any)) agentParse {
	agent := raw.Get("agent")
	command := parseCommand(agent.Get("command"), "agent", add)
	env := parseEnv(agent.Get("envPassthrough"), "agent", add)
	secretsFile, secretNames, secretsIgnored, secretErrs := validateSecrets(agent.Get("secretsFile"), env)
	for _, e := range secretErrs {
		add("%s", e)
	}
	return agentParse{
		specs: []agentSpec{{
			AgentRunner: AgentRunner{ID: "default", Name: "default", Command: command, EnvPassthrough: env},
			imageRaw:    raw.Get("runner").Get("image"),
		}},
		defaultRunner:  "default",
		secretsFile:    secretsFile,
		secretNames:    secretNames,
		secretsIgnored: secretsIgnored,
	}
}

// parseCommand reads an argv array. A shell string is refused.
func parseCommand(v *jsonv.Value, what string, add func(string, ...any)) []string {
	ok := v != nil && v.Kind == jsonv.Array && len(v.Arr) > 0
	var command []string
	if ok {
		for _, part := range v.Arr {
			s, good := part.StringValue()
			if !good || s == "" {
				ok = false
				break
			}
			command = append(command, s)
		}
	}
	if !ok {
		add("%s.command must be a non-empty array of strings (no shell string)", what)
		return nil
	}
	return command
}

// parseEnv reads the names of the environment variables an agent may receive. Absent means PATH
// and HOME.
func parseEnv(v *jsonv.Value, what string, add func(string, ...any)) []string {
	if v.IsNull() {
		return []string{"PATH", "HOME"}
	}
	ok := v.Kind == jsonv.Array
	var names []string
	if ok {
		for _, n := range v.Arr {
			s, good := n.StringValue()
			if !good || !envName.MatchString(s) {
				ok = false
				break
			}
			names = append(names, s)
		}
	}
	if !ok {
		add("%s.envPassthrough must be an array of environment variable names", what)
	}
	return names
}
