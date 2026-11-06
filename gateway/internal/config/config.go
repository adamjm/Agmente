// Package config loads and validates the gateway config file (SPEC 6.3, FR-2, NFR-14).
// Error messages are part of the CLI contract: the wire tests match them.
package config

import (
	"errors"
	"fmt"
	"io/fs"
	"math"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"agmente/gateway/internal/jsonv"
)

// Error lists every problem found in a config, so one run reports them all.
type Error struct{ Errors []string }

func (e *Error) Error() string {
	return "Invalid gateway config:\n- " + strings.Join(e.Errors, "\n- ")
}

type Token struct {
	ID, Identity, SHA256 string
}

type Limits struct {
	MaxMessageBytes int64 `json:"maxMessageBytes"`
	// MaxAgentsPerIdentity is accepted but no longer used: since D-025 agents run per project,
	// not per connection. Connections are capped by MaxConnectionsPerIdentity.

	MaxAgentsPerIdentity      int64 `json:"maxAgentsPerIdentity"`
	MaxAgentsTotal            int64 `json:"maxAgentsTotal"`
	MaxConnectionsPerIdentity int64 `json:"maxConnectionsPerIdentity"`
	AuthFailuresPerWindow     int64 `json:"authFailuresPerWindow"`
	AuthWindowSeconds         int64 `json:"authWindowSeconds"`
	LockoutSeconds            int64 `json:"lockoutSeconds"`
	ApprovalTimeoutSeconds    int64 `json:"approvalTimeoutSeconds"`
	IdleSeconds               int64 `json:"idleSeconds"`
}

// Runner says how a project's agent starts (D-025): "host" (tests and development only) or
// "podman" (one container per project, D-008).
type Runner struct {
	Kind   string `json:"kind"`
	Image  string `json:"image,omitempty"`
	Podman string `json:"podman,omitempty"`
	// ContainerUID and ContainerGID are the user inside the project image (D-051). The podman
	// runner maps the gateway's own user onto it (`--userns=keep-id`), so the container user owns
	// the project home, the snapshot folder and the project folder as the gateway user does. Zero
	// means DefaultContainerID.
	ContainerUID int `json:"containerUid,omitempty"`
	ContainerGID int `json:"containerGid,omitempty"`
}

// DefaultContainerID is the uid and gid of the user in deploy/bob-project.Containerfile.
const DefaultContainerID = 10001

// Push is the APNs delivery block (PLAN 3.11, D-053, D-055). It holds paths and ids only: the key
// itself stays in its file, which must not be readable by group or others. The URL overrides and
// caFile exist for tests; a real deployment leaves them out.
type Push struct {
	KeyFile       string
	KeyID         string
	TeamID        string
	Topic         string
	SandboxURL    string // optional; default https://api.sandbox.push.apple.com
	ProductionURL string // optional; default https://api.push.apple.com
	CAFile        string // test only: a CA that trusts a fake APNs server
}

type Config struct {
	Push           *Push // nil when the push block is absent: delivery is off
	Runner         Runner
	ListenHost     string
	ListenPort     int
	TrustProxy     bool
	Tokens         []Token
	AgentCommand   []string
	EnvPassthrough []string
	Roots          []string
	StateDir       string
	Limits         Limits
}

// limitKeys in the order of DEFAULT_LIMITS (SPEC NFR-3, NFR-4, NFR-5).
var limitKeys = []string{"maxMessageBytes", "maxAgentsPerIdentity", "maxAgentsTotal", "maxConnectionsPerIdentity", "authFailuresPerWindow", "authWindowSeconds", "lockoutSeconds", "approvalTimeoutSeconds", "idleSeconds"}

var defaultLimits = map[string]int64{
	"maxMessageBytes":           16 * 1024 * 1024, // NFR-3
	"maxAgentsPerIdentity":      4,                // NFR-4
	"maxAgentsTotal":            16,               // NFR-4
	"maxConnectionsPerIdentity": 8,                // D-025
	"authFailuresPerWindow":     10,               // NFR-5
	"authWindowSeconds":         60,               // NFR-5
	"lockoutSeconds":            600,              // NFR-5
	"approvalTimeoutSeconds":    43200,            // NFR-10: 12 h, then reject (D-031)
	"idleSeconds":               1800,             // NFR-10: idle close after 30 min (D-032)
}

var (
	loopbackIPv4 = regexp.MustCompile(`^127\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$`)
	hex64        = regexp.MustCompile(`^[0-9a-f]{64}$`)
	safeID       = regexp.MustCompile(`^[A-Za-z0-9._-]{1,64}$`)
	envName      = regexp.MustCompile(`^[A-Z_][A-Z0-9_]*$`)
)

const safeIDText = `/^[A-Za-z0-9._-]{1,64}$/`

// IsLoopbackAddress is true for IPv4 127/8, IPv6 ::1, an IPv4-mapped 127/8, and "localhost".
func IsLoopbackAddress(address string) bool {
	a := strings.ToLower(strings.TrimSpace(address))
	if a == "localhost" || a == "::1" || a == "[::1]" {
		return true
	}
	a = strings.TrimPrefix(a, "::ffff:")
	return loopbackIPv4.MatchString(a)
}

// Validate checks a parsed config and returns a normalized copy, or an *Error.
func Validate(raw *jsonv.Value) (*Config, error) {
	if raw == nil || raw.Kind != jsonv.Object {
		return nil, &Error{[]string{"config must be a JSON object"}}
	}
	var errs []string
	add := func(format string, args ...any) { errs = append(errs, fmt.Sprintf(format, args...)) }

	listen := raw.Get("listen")
	host, hostIsString := listen.Get("host").StringValue()
	if !hostIsString || !IsLoopbackAddress(host) {
		add("listen.host must be a loopback address (127.0.0.1, ::1 or localhost). Put Caddy in front for public access.")
	}
	port, portOK := listen.Get("port").Int()
	if !portOK || port < 0 || port > 65535 {
		add("listen.port must be an integer from 0 to 65535")
	}

	trustProxy := false
	if tp := raw.Get("trustProxy"); tp != nil {
		if tp.Kind != jsonv.Bool {
			add("trustProxy must be true or false")
		} else {
			trustProxy = tp.B
		}
	}

	var tokenValues []*jsonv.Value
	if t := raw.Get("tokens"); t != nil && t.Kind == jsonv.Array {
		tokenValues = t.Arr
	}
	if len(tokenValues) == 0 {
		add("tokens must hold at least one entry")
	}
	seen := map[string]bool{}
	tokens := make([]Token, 0, len(tokenValues))
	for i, t := range tokenValues {
		if t.Kind != jsonv.Object && t.Kind != jsonv.Array {
			add("tokens[%d] must be an object", i)
			continue
		}
		id, _ := t.Get("id").StringValue()
		identity, _ := t.Get("identity").StringValue()
		sha, _ := t.Get("sha256").StringValue()
		if !safeID.MatchString(id) {
			add("tokens[%d].id must match %s", i, safeIDText)
		}
		if !safeID.MatchString(identity) {
			add("tokens[%d].identity must match %s", i, safeIDText)
		}
		if !hex64.MatchString(sha) {
			add("tokens[%d].sha256 must be 64 lowercase hex characters (store the hash, never the token)", i)
		}
		if t.Get("token") != nil || t.Get("secret") != nil {
			add("tokens[%d] must not contain a raw token (NFR-14)", i)
		}
		if seen[id] {
			add("tokens[%d].id \"%s\" is a duplicate", i, id)
		}
		seen[id] = true
		tokens = append(tokens, Token{ID: id, Identity: identity, SHA256: sha})
	}

	agent := raw.Get("agent")
	var command []string
	cmdOK := false
	if c := agent.Get("command"); c != nil && c.Kind == jsonv.Array && len(c.Arr) > 0 {
		cmdOK = true
		for _, part := range c.Arr {
			s, ok := part.StringValue()
			if !ok || s == "" {
				cmdOK = false
				break
			}
			command = append(command, s)
		}
	}
	if !cmdOK {
		add("agent.command must be a non-empty array of strings (no shell string)")
	}
	envPassthrough := []string{"PATH", "HOME"}
	if e := agent.Get("envPassthrough"); !e.IsNull() {
		envOK := e.Kind == jsonv.Array
		var names []string
		if envOK {
			for _, n := range e.Arr {
				s, ok := n.StringValue()
				if !ok || !envName.MatchString(s) {
					envOK = false
					break
				}
				names = append(names, s)
			}
		}
		if !envOK {
			add("agent.envPassthrough must be an array of environment variable names")
		}
		envPassthrough = names
	}

	var roots []string
	r := raw.Get("projects").Get("roots")
	if r == nil || r.Kind != jsonv.Array || len(r.Arr) == 0 {
		add("projects.roots must hold at least one absolute path")
	} else {
		for i, item := range r.Arr {
			s, ok := item.StringValue()
			if !ok || !filepath.IsAbs(s) {
				add("projects.roots[%d] must be an absolute path", i)
			}
			if ok && s == "/" {
				add("projects.roots[%d] must not be \"/\"", i)
			}
			roots = append(roots, s)
		}
	}

	stateDir, stateOK := raw.Get("stateDir").StringValue()
	if !stateOK || !filepath.IsAbs(stateDir) || filepath.Clean(stateDir) == "/" {
		add("stateDir must be an absolute path other than \"/\" (the gateway keeps its database and project homes there)")
	}

	pushCfg := validatePush(raw.Get("push"), add)

	var runner Runner
	rv := raw.Get("runner")
	kind, _ := rv.Get("kind").StringValue()
	switch kind {
	case "host":
		if allow := rv.Get("allowHost"); allow == nil || allow.Kind != jsonv.Bool || !allow.B {
			add("runner.kind \"host\" runs agents without a container; it needs runner.allowHost: true and is for tests and development only (D-008)")
		}
		runner = Runner{Kind: "host"}
	case "podman":
		image, ok := rv.Get("image").StringValue()
		if !ok || image == "" || strings.HasPrefix(image, "-") {
			add("runner.image must name the project image, for example \"agmente-bob:2.0.9\"")
		}
		podman := "podman"
		if p := rv.Get("podman"); !p.IsNull() {
			s, ok := p.StringValue()
			if !ok || !filepath.IsAbs(s) {
				add("runner.podman must be an absolute path to the podman binary")
			}
			podman = s
		}
		runner = Runner{Kind: "podman", Image: image, Podman: podman}
		for _, id := range []struct {
			key string
			dst *int
		}{{"containerUid", &runner.ContainerUID}, {"containerGid", &runner.ContainerGID}} {
			v := rv.Get(id.key)
			if v.IsNull() {
				continue
			}
			n, ok := v.Int()
			if !ok || n < 1 || n > 65535 {
				add("runner.%s must be an integer from 1 to 65535 (the user inside the image; 0 would be root)", id.key)
				continue
			}
			*id.dst = int(n)
		}
	default:
		add("runner.kind must be \"podman\" or \"host\"")
	}

	limits := map[string]int64{}
	for k, v := range defaultLimits {
		limits[k] = v
	}
	rawLimits := raw.Get("limits")
	limitValue := func(key string) (*jsonv.Value, bool) {
		if rawLimits == nil || rawLimits.Kind != jsonv.Object {
			return nil, false
		}
		v, ok := rawLimits.Obj[key]
		return v, ok
	}
	limitsValid := true
	for _, key := range limitKeys {
		v, ok := limitValue(key)
		if !ok {
			continue
		}
		n, isInt := v.Int()
		if !isInt || n < 1 {
			add("limits.%s must be a positive integer", key)
			limitsValid = false
			continue
		}
		limits[key] = n
	}
	if rawLimits != nil && rawLimits.Kind == jsonv.Object {
		for _, key := range rawLimits.Keys {
			if _, known := defaultLimits[key]; !known {
				add("limits.%s is not a known limit", key)
			}
		}
	}
	if limitsValid && limits["maxAgentsPerIdentity"] > limits["maxAgentsTotal"] {
		add("limits.maxAgentsPerIdentity must not exceed limits.maxAgentsTotal")
	}

	if len(errs) > 0 {
		return nil, &Error{errs}
	}
	return &Config{
		Push:           pushCfg,
		Runner:         runner,
		ListenHost:     host,
		ListenPort:     int(port),
		TrustProxy:     trustProxy,
		Tokens:         tokens,
		AgentCommand:   command,
		EnvPassthrough: envPassthrough,
		Roots:          roots,
		StateDir:       filepath.Clean(stateDir),
		Limits: Limits{
			MaxMessageBytes:           limits["maxMessageBytes"],
			MaxAgentsPerIdentity:      limits["maxAgentsPerIdentity"],
			MaxAgentsTotal:            limits["maxAgentsTotal"],
			MaxConnectionsPerIdentity: limits["maxConnectionsPerIdentity"],
			AuthFailuresPerWindow:     limits["authFailuresPerWindow"],
			AuthWindowSeconds:         limits["authWindowSeconds"],
			ApprovalTimeoutSeconds:    min(limits["approvalTimeoutSeconds"], math.MaxInt32),
			IdleSeconds:               min(limits["idleSeconds"], math.MaxInt32),
			LockoutSeconds:            min(limits["lockoutSeconds"], math.MaxInt32),
		},
	}, nil
}

var (
	apnsKeyID = regexp.MustCompile(`^[A-Z0-9]{10}$`)
	apnsTopic = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9.-]{0,199}$`)
)

var pushKeys = map[string]bool{"keyFile": true, "keyId": true, "teamId": true, "topic": true, "sandboxURL": true, "productionURL": true, "caFile": true}

// validatePush checks the push block. A null or missing block means delivery is off (nil).
func validatePush(v *jsonv.Value, add func(string, ...any)) *Push {
	if v.IsNull() {
		return nil
	}
	if v.Kind != jsonv.Object {
		add("push must be an object (or left out to turn delivery off)")
		return nil
	}
	for _, k := range v.Keys {
		if !pushKeys[k] {
			add("push.%s is not a known key", k)
		}
	}
	str := func(key string) string {
		s, _ := v.Get(key).StringValue()
		return s
	}
	p := &Push{KeyFile: str("keyFile"), KeyID: str("keyId"), TeamID: str("teamId"), Topic: str("topic")}
	ok := true
	if !filepath.IsAbs(p.KeyFile) {
		add("push.keyFile must be an absolute path to the APNs .p8 key (the key itself never goes in the config)")
		ok = false
	}
	if !apnsKeyID.MatchString(p.KeyID) {
		add("push.keyId must be the 10-character APNs key id")
		ok = false
	}
	if !apnsKeyID.MatchString(p.TeamID) {
		add("push.teamId must be the 10-character Apple team id")
		ok = false
	}
	if !apnsTopic.MatchString(p.Topic) {
		add("push.topic must be the app's bundle id")
		ok = false
	}
	for _, item := range []struct {
		key string
		dst *string
	}{{"sandboxURL", &p.SandboxURL}, {"productionURL", &p.ProductionURL}} {
		if v.Get(item.key).IsNull() {
			continue
		}
		if !validHTTPSBase(str(item.key)) {
			add("push.%s must be an https URL with a host and no path, query or user", item.key)
			ok = false
			continue
		}
		*item.dst = str(item.key)
	}
	if !v.Get("caFile").IsNull() {
		p.CAFile = str("caFile")
		if !filepath.IsAbs(p.CAFile) {
			add("push.caFile must be an absolute path (test only)")
			ok = false
		}
	}
	if !ok {
		return nil
	}
	return p
}

func validHTTPSBase(s string) bool {
	u, err := url.Parse(s)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return false
	}
	return u.Path == "" || u.Path == "/"
}

// Load reads, parses and validates a config file.
func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, &Error{[]string{fmt.Sprintf("cannot read %s: %s", path, errnoName(err))}}
	}
	raw, err := jsonv.Parse(data)
	if err != nil {
		return nil, &Error{[]string{fmt.Sprintf("%s is not valid JSON: %v", path, err)}}
	}
	return Validate(raw)
}

func errnoName(err error) string {
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return "ENOENT"
	case errors.Is(err, fs.ErrPermission):
		return "EACCES"
	default:
		var pe *fs.PathError
		if errors.As(err, &pe) {
			return pe.Err.Error()
		}
		return err.Error()
	}
}
