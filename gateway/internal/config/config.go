// Package config loads and validates the gateway config file (SPEC 6.3, FR-2, NFR-14).
// Error messages are part of the CLI contract: the wire tests match them.
package config

import (
	"errors"
	"fmt"
	"io/fs"
	"math"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"acpcode/gateway/internal/jsonv"
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
	StallSeconds              int64 `json:"stallSeconds"` // a turn with no event for this long is flagged stalled (D-106)
}

// Runner says how a project's agent starts (D-025): "host" (tests and development only) or
// "podman" (one container per project, D-008).
type Runner struct {
	Kind   string `json:"kind"`
	Image  string `json:"image,omitempty"`
	Podman string `json:"podman,omitempty"`
	// Container is the Apple `container` CLI for kind "apple" (D-079). Absolute when set.
	Container string `json:"container,omitempty"`
	// DNS is the nameserver the Apple runner gives its containers (--dns), an IP address. Empty
	// means the default: on the Mac tested (D-079), that resolver did not answer, so Bob could not
	// reach its service. A set value sends lookups from the containers to that server unencrypted.
	DNS string `json:"dns,omitempty"`
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
	Files          *Files // signed file URLs (PLAN 5.3); nil when off
	// SecretsFile is the absolute path of agent.secretsFile, "" when absent (PLAN 4.2). It holds
	// NAME=value lines; the gateway reads it at each agent start and never stores the values.
	SecretsFile string
	// SecretNames are the names in the file that the agent may receive (listed in envPassthrough).
	SecretNames []string
	// SecretsIgnored are names in the file that envPassthrough does not list. They are ignored and
	// logged by name only.
	SecretsIgnored []string
	// Connector is the remote connector block (D-095). Enabled is false unless the block says so.
	Connector Connector
	// GitHosts are the hosts a git remote and a git credential may name (D-105). Default github.com.
	GitHosts []string
}

// limitKeys in the order of DEFAULT_LIMITS (SPEC NFR-3, NFR-4, NFR-5).
var limitKeys = []string{"maxMessageBytes", "maxAgentsPerIdentity", "maxAgentsTotal", "maxConnectionsPerIdentity", "authFailuresPerWindow", "authWindowSeconds", "lockoutSeconds", "approvalTimeoutSeconds", "idleSeconds", "stallSeconds"}

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
	"stallSeconds":              600,              // D-106: a turn with no event for this long is flagged stalled
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
	secretsFile, secretNames, secretsIgnored, secretErrs := validateSecrets(agent.Get("secretsFile"), envPassthrough)
	errs = append(errs, secretErrs...)

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
	case "podman", "apple":
		image, ok := rv.Get("image").StringValue()
		if !ok || image == "" || strings.HasPrefix(image, "-") {
			add("runner.image must name the project image, for example \"acpcode-bob:2.0.9\"")
		}
		podman, cli := "podman", "container"
		if kind == "apple" {
			cli = "container"
			if p := rv.Get("container"); !p.IsNull() {
				s, ok := p.StringValue()
				if !ok || !filepath.IsAbs(s) {
					add("runner.container must be an absolute path to the Apple container binary")
				}
				cli = s
			}
		} else if p := rv.Get("podman"); !p.IsNull() {
			s, ok := p.StringValue()
			if !ok || !filepath.IsAbs(s) {
				add("runner.podman must be an absolute path to the podman binary")
			}
			podman = s
		}
		runner = Runner{Kind: kind, Image: image, Podman: podman, Container: cli}
		if kind == "apple" {
			runner.Podman = ""
			if d := rv.Get("dns"); !d.IsNull() {
				s, ok := d.StringValue()
				if !ok || net.ParseIP(s) == nil {
					add("runner.dns must be an IP address of a nameserver, for example \"1.1.1.1\"")
				} else {
					runner.DNS = s
				}
			}
		} else {
			runner.Container = ""
		}
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
		add("runner.kind must be \"podman\", \"apple\" or \"host\"")
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

	filesCfg, filesErrs := validateFiles(raw.Get("files"))
	errs = append(errs, filesErrs...)

	connectorCfg, connectorErrs := validateConnector(raw.Get("connector"))
	errs = append(errs, connectorErrs...)

	gitHosts := validateGit(raw.Get("git"), add)

	if len(errs) > 0 {
		return nil, &Error{errs}
	}
	return &Config{
		Push:           pushCfg,
		Files:          filesCfg,
		Runner:         runner,
		ListenHost:     host,
		ListenPort:     int(port),
		TrustProxy:     trustProxy,
		Tokens:         tokens,
		AgentCommand:   command,
		EnvPassthrough: envPassthrough,
		SecretsFile:    secretsFile,
		SecretNames:    secretNames,
		SecretsIgnored: secretsIgnored,
		Connector:      connectorCfg,
		GitHosts:       gitHosts,
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
			StallSeconds:              min(limits["stallSeconds"], math.MaxInt32),
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

// Connector is the remote connector block (D-095, contract C6). The public listener is separate
// from the phone's: it binds 127.0.0.1:Port and Caddy forwards to it without a client certificate.
type Connector struct {
	Enabled               bool
	Port                  int
	PublicOrigin          string   // https origin the client reaches through Caddy, no path
	AllowedOrigins        []string // Origin values a browser may send; a request with no Origin is always allowed
	PairingTimeoutSeconds int64
	Limits                ConnectorLimits
}

// ConnectorLimits are the connector's per-grant and per-gateway limits (C6).
type ConnectorLimits struct {
	MaxConcurrentTurns    int64
	PromptsPerHour        int64
	MaxPromptBytes        int64
	MaxResultChars        int64
	SendPromptWaitSeconds int64
}

// DefaultConnectorPort is the connector listener's port when the block does not name one.
const DefaultConnectorPort = 8789

var connectorKeys = map[string]bool{"enabled": true, "port": true, "publicOrigin": true, "allowedOrigins": true, "pairingTimeoutSeconds": true, "limits": true}

// connectorLimitRanges are the accepted values of each connector limit (C6). The defaults are set in
// validateConnector.
var connectorLimitRanges = []struct {
	key      string
	min, max int64
}{
	{"maxConcurrentTurns", 1, 16},
	{"promptsPerHour", 1, 1000},
	{"maxPromptBytes", 1, 65536},
	{"maxResultChars", 1000, 200000},
	{"sendPromptWaitSeconds", 1, 600},
}

const maxConnectorOrigins = 20

// validateConnector checks the connector block. A missing or null block is the default: off.
func validateConnector(v *jsonv.Value) (Connector, []string) {
	c := Connector{Port: DefaultConnectorPort, PairingTimeoutSeconds: 300}
	c.Limits = ConnectorLimits{MaxConcurrentTurns: 1, PromptsPerHour: 20, MaxPromptBytes: 8192, MaxResultChars: 20000, SendPromptWaitSeconds: 200}
	if v.IsNull() {
		return c, nil
	}
	if v.Kind != jsonv.Object {
		return c, []string{"connector must be an object (or left out to turn the connector off)"}
	}
	var errs []string
	for _, k := range v.Keys {
		if !connectorKeys[k] {
			errs = append(errs, fmt.Sprintf("connector.%s is not a known key", k))
		}
	}

	if e := v.Get("enabled"); !e.IsNull() {
		if e.Kind != jsonv.Bool {
			errs = append(errs, "connector.enabled must be true or false")
		} else {
			c.Enabled = e.B
		}
	}
	if p := v.Get("port"); !p.IsNull() {
		n, ok := p.Int()
		if !ok || n < 1 || n > 65535 {
			errs = append(errs, "connector.port must be an integer from 1 to 65535")
		} else {
			c.Port = int(n)
		}
	}
	if o := v.Get("publicOrigin"); !o.IsNull() {
		s, ok := o.StringValue()
		if !ok || !validHTTPSOrigin(s) {
			errs = append(errs, "connector.publicOrigin must be an https origin: https, a host, an optional port, and no path, query or fragment (for example https://name.example or https://name.example:8443)")
		} else {
			c.PublicOrigin = s
		}
	}
	if c.Enabled && c.PublicOrigin == "" {
		errs = append(errs, "connector.publicOrigin must be set when connector.enabled is true (the https address Claude reaches, D-095)")
	}
	if ao := v.Get("allowedOrigins"); !ao.IsNull() {
		if ao.Kind != jsonv.Array || len(ao.Arr) > maxConnectorOrigins {
			errs = append(errs, fmt.Sprintf("connector.allowedOrigins must be an array of at most %d https origins", maxConnectorOrigins))
		} else {
			for i, item := range ao.Arr {
				s, ok := item.StringValue()
				if !ok || !validHTTPSOrigin(s) {
					errs = append(errs, fmt.Sprintf("connector.allowedOrigins[%d] must be an https origin with a host and no path", i))
					continue
				}
				c.AllowedOrigins = append(c.AllowedOrigins, s)
			}
		}
	}
	if t := v.Get("pairingTimeoutSeconds"); !t.IsNull() {
		n, ok := t.Int()
		if !ok || n < 1 || n > 3600 {
			errs = append(errs, "connector.pairingTimeoutSeconds must be an integer from 1 to 3600")
		} else {
			c.PairingTimeoutSeconds = n
		}
	}

	lim := v.Get("limits")
	if !lim.IsNull() && lim.Kind != jsonv.Object {
		errs = append(errs, "connector.limits must be an object")
		lim = nil
	}
	if lim != nil {
		known := map[string]bool{}
		for _, r := range connectorLimitRanges {
			known[r.key] = true
		}
		for _, k := range lim.Keys {
			if !known[k] {
				errs = append(errs, fmt.Sprintf("connector.limits.%s is not a known limit", k))
			}
		}
	}
	values := map[string]*int64{
		"maxConcurrentTurns":    &c.Limits.MaxConcurrentTurns,
		"promptsPerHour":        &c.Limits.PromptsPerHour,
		"maxPromptBytes":        &c.Limits.MaxPromptBytes,
		"maxResultChars":        &c.Limits.MaxResultChars,
		"sendPromptWaitSeconds": &c.Limits.SendPromptWaitSeconds,
	}
	for _, r := range connectorLimitRanges {
		if lim == nil {
			break
		}
		v := lim.Get(r.key)
		if v.IsNull() {
			continue
		}
		n, ok := v.Int()
		if !ok || n < r.min || n > r.max {
			errs = append(errs, fmt.Sprintf("connector.limits.%s must be an integer from %d to %d", r.key, r.min, r.max))
			continue
		}
		*values[r.key] = n
	}
	return c, errs
}

func validHTTPSBase(s string) bool {
	u, err := url.Parse(s)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return false
	}
	return u.Path == "" || u.Path == "/"
}

// validHTTPSOrigin accepts an https origin: a scheme, a host, an optional port from 1 to 65535, and
// nothing else. A path is refused, a trailing slash included, because the resource identifier is the
// origin plus /mcp and "https://name.example/" would make "https://name.example//mcp" (D-101).
func validHTTPSOrigin(s string) bool {
	u, err := url.Parse(s)
	if err != nil || u.Scheme != "https" || u.Opaque != "" || u.User != nil || u.Path != "" ||
		u.RawQuery != "" || u.ForceQuery || u.Fragment != "" || u.Hostname() == "" {
		return false
	}
	if strings.HasSuffix(u.Host, ":") { // an empty port
		return false
	}
	if p := u.Port(); p != "" {
		n, err := strconv.Atoi(p)
		if err != nil || n < 1 || n > 65535 || strings.Trim(p, "0123456789") != "" {
			return false
		}
	}
	return true
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
