// Package mcpservers is the gateway's own list of MCP servers (D-107). The Mac admin adds, changes
// and removes entries with the `mcp-server` command. The phone can only list them and pick their
// ids per session. Non-secret fields live in mcp-servers.json; secret values (header values, stdio
// arguments and environment values) live in mcp-secrets.json. Both are mode 0600, written with
// mcpconf.Write (atomic, symlink refused), and read on every use, so a restart keeps everything.
// Nothing here runs a program. Errors name a field, never a value.
package mcpservers

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"acpcode/gateway/internal/mcpconf"
)

const (
	listFile    = "mcp-servers.json"
	secretsFile = "mcp-secrets.json"

	MaxEntries    = 32   // entries in the list
	maxName       = 64   // bytes
	maxURL        = 2048 // bytes
	maxValue      = 4096 // bytes, for any header, argument or environment value
	maxHeaderName = 128
	maxArgs       = 32
	maxHeaders    = 16
	maxEnv        = 32
	maxCommand    = 1024
)

var (
	// ErrInvalid is a refusal of an entry. Its text names the field, never a value.
	ErrInvalid = errors.New("invalid MCP server")
	// ErrNotFound means no entry has the id.
	ErrNotFound = errors.New("no MCP server with that id")

	idPattern = regexp.MustCompile(`^[0-9a-f]{32}$`)
	// mu serialises every read and write of the two files in this process.
	mu sync.Mutex
)

// ValidID reports whether s has the shape of an entry id (32 lowercase hex digits).
func ValidID(s string) bool { return idPattern.MatchString(s) }

// Entry is one server's non-secret fields, as stored.
type Entry struct {
	ID             string    `json:"id"`
	Name           string    `json:"name"`
	Transport      string    `json:"transport"`         // "http" or "stdio"
	URL            string    `json:"url,omitempty"`     // http only; no credentials, no query
	Command        string    `json:"command,omitempty"` // stdio only; never sent to a phone
	DefaultEnabled bool      `json:"defaultEnabled"`
	CreatedAt      time.Time `json:"createdAt"`
}

// Pair is a name and a value: an HTTP header, or an environment variable.
type Pair struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

// Secrets are the values that never leave the gateway host except inside a session request to the
// agent: header values, stdio arguments and environment values.
type Secrets struct {
	Args    []string `json:"args,omitempty"`
	Headers []Pair   `json:"headers,omitempty"`
	Env     []Pair   `json:"env,omitempty"`
}

// Input is an entry the admin gives. An empty ID adds an entry; a known ID replaces it.
type Input struct {
	ID             string   `json:"id"`
	Name           string   `json:"name"`
	Transport      string   `json:"transport"`
	URL            string   `json:"url"`
	Command        string   `json:"command"`
	Args           []string `json:"args"`
	Headers        []Pair   `json:"headers"`
	Env            []Pair   `json:"env"`
	DefaultEnabled bool     `json:"defaultEnabled"`
}

// Listed is an entry as a phone may see it: no command, no argument, no header or environment value.
// A URL that carries a query or credentials is shown as its scheme and host only.
type Listed struct {
	ID             string `json:"id"`
	Name           string `json:"name"`
	Transport      string `json:"transport"`
	URL            string `json:"url,omitempty"`
	DefaultEnabled bool   `json:"defaultEnabled"`
}

// Full is an entry with its secrets, for the gateway to send to an agent.
type Full struct {
	Entry   Entry
	Secrets Secrets
}

// Library is the gateway's MCP server list in one state directory.
type Library struct{ dir string }

// Open returns the list in stateDir. It reads nothing until a method is called.
func Open(stateDir string) *Library { return &Library{dir: stateDir} }

type listDoc struct {
	Version int     `json:"version"`
	Servers []Entry `json:"servers"`
}

type secretsDoc struct {
	Version int                `json:"version"`
	Servers map[string]Secrets `json:"servers"`
}

// read loads both files. A missing file is empty.
func (l *Library) read() (listDoc, secretsDoc, error) {
	list := listDoc{Version: 1}
	secrets := secretsDoc{Version: 1, Servers: map[string]Secrets{}}
	if data, err := mcpconf.Read(filepath.Join(l.dir, listFile)); err == nil {
		if err := json.Unmarshal(data, &list); err != nil {
			return list, secrets, errors.New("the MCP server list is not valid JSON")
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return list, secrets, fmt.Errorf("cannot read the MCP server list: %w", err)
	}
	if data, err := mcpconf.Read(filepath.Join(l.dir, secretsFile)); err == nil {
		if err := json.Unmarshal(data, &secrets); err != nil {
			return list, secrets, errors.New("the MCP secrets file is not valid JSON")
		}
		if secrets.Servers == nil {
			secrets.Servers = map[string]Secrets{}
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return list, secrets, fmt.Errorf("cannot read the MCP secrets file: %w", err)
	}
	return list, secrets, nil
}

// write stores both files: the secrets first, so a crash never leaves an entry without its values.
func (l *Library) write(list listDoc, secrets secretsDoc) error {
	secrets.Version, list.Version = 1, 1
	sdata, err := json.MarshalIndent(secrets, "", "  ")
	if err != nil {
		return err
	}
	if err := mcpconf.Write(filepath.Join(l.dir, secretsFile), append(sdata, '\n')); err != nil {
		return fmt.Errorf("cannot write the MCP secrets file: %w", err)
	}
	ldata, err := json.MarshalIndent(list, "", "  ")
	if err != nil {
		return err
	}
	if err := mcpconf.Write(filepath.Join(l.dir, listFile), append(ldata, '\n')); err != nil {
		return fmt.Errorf("cannot write the MCP server list: %w", err)
	}
	return nil
}

// Entries returns the stored entries, in the order they were added.
func (l *Library) Entries() ([]Entry, error) {
	mu.Lock()
	defer mu.Unlock()
	list, _, err := l.read()
	return list.Servers, err
}

// List returns the entries as a phone may see them.
func (l *Library) List() ([]Listed, error) {
	entries, err := l.Entries()
	if err != nil {
		return nil, err
	}
	out := make([]Listed, 0, len(entries))
	for _, e := range entries {
		out = append(out, Redact(e))
	}
	return out, nil
}

// DefaultIDs returns the ids of the entries that start enabled in a new session.
func (l *Library) DefaultIDs() ([]string, error) {
	entries, err := l.Entries()
	if err != nil {
		return nil, err
	}
	var ids []string
	for _, e := range entries {
		if e.DefaultEnabled {
			ids = append(ids, e.ID)
		}
	}
	return ids, nil
}

// Resolve looks up ids. It returns the entries found, in the order asked, and the ids that are not
// in the list (a removed entry, or one that never existed). It never fails for a missing id.
func (l *Library) Resolve(ids []string) (found []Full, missing []string, err error) {
	mu.Lock()
	defer mu.Unlock()
	list, secrets, err := l.read()
	if err != nil {
		return nil, nil, err
	}
	byID := make(map[string]Entry, len(list.Servers))
	for _, e := range list.Servers {
		byID[e.ID] = e
	}
	for _, id := range ids {
		e, ok := byID[id]
		if !ok {
			missing = append(missing, id)
			continue
		}
		found = append(found, Full{Entry: e, Secrets: secrets.Servers[id]})
	}
	return found, missing, nil
}

// Put adds an entry, or replaces the one with in.ID. It validates the input first, and it refuses a
// list that would hold more than MaxEntries entries or two entries with one name.
func (l *Library) Put(in Input) (Entry, error) {
	if err := validate(in); err != nil {
		return Entry{}, err
	}
	mu.Lock()
	defer mu.Unlock()
	list, secrets, err := l.read()
	if err != nil {
		return Entry{}, err
	}
	entry := Entry{ID: in.ID, Name: in.Name, Transport: in.Transport, DefaultEnabled: in.DefaultEnabled, CreatedAt: time.Now().UTC().Truncate(time.Second)}
	if in.Transport == "http" {
		entry.URL = in.URL
	} else {
		entry.Command = in.Command
	}
	at := -1
	if in.ID != "" {
		for i, e := range list.Servers {
			if e.ID == in.ID {
				at = i
			}
		}
		if at < 0 {
			return Entry{}, ErrNotFound
		}
		entry.CreatedAt = list.Servers[at].CreatedAt
	} else {
		if len(list.Servers) >= MaxEntries {
			return Entry{}, fmt.Errorf("%w: the list holds at most %d servers", ErrInvalid, MaxEntries)
		}
		id, err := newID()
		if err != nil {
			return Entry{}, err
		}
		entry.ID = id
	}
	for i, e := range list.Servers {
		if i != at && e.Name == in.Name {
			return Entry{}, fmt.Errorf("%w: another server has this name", ErrInvalid)
		}
	}
	sec := Secrets{Args: in.Args, Headers: in.Headers, Env: in.Env}
	if in.Transport == "http" {
		sec.Args, sec.Env = nil, nil
	} else {
		sec.Headers = nil
	}
	if sec.Args == nil && sec.Headers == nil && sec.Env == nil {
		delete(secrets.Servers, entry.ID)
	} else {
		secrets.Servers[entry.ID] = sec
	}
	if at >= 0 {
		list.Servers[at] = entry
	} else {
		list.Servers = append(list.Servers, entry)
	}
	if err := l.write(list, secrets); err != nil {
		return Entry{}, err
	}
	return entry, nil
}

// Delete removes an entry and its secret values. It reports whether the id was in the list.
func (l *Library) Delete(id string) (bool, error) {
	mu.Lock()
	defer mu.Unlock()
	list, secrets, err := l.read()
	if err != nil {
		return false, err
	}
	kept := list.Servers[:0]
	found := false
	for _, e := range list.Servers {
		if e.ID == id {
			found = true
			continue
		}
		kept = append(kept, e)
	}
	if !found {
		return false, nil
	}
	list.Servers = kept
	delete(secrets.Servers, id)
	return true, l.write(list, secrets)
}

// Redact returns the phone's view of an entry.
func Redact(e Entry) Listed {
	return Listed{ID: e.ID, Name: e.Name, Transport: e.Transport, URL: redactURL(e.URL), DefaultEnabled: e.DefaultEnabled}
}

// redactURL keeps a URL as it is when it has no query and no credentials. Otherwise it keeps the
// scheme and the host only (the query may hold a token; the path is kept).
func redactURL(raw string) string {
	if raw == "" {
		return ""
	}
	u, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	if u.User == nil && u.RawQuery == "" && u.Fragment == "" && !strings.Contains(raw, "?") {
		return raw
	}
	return u.Scheme + "://" + u.Host
}

// validate checks an input against the rules of the list. Errors name the field only.
func validate(in Input) error {
	if in.ID != "" && !ValidID(in.ID) {
		return fmt.Errorf("%w: id is not valid", ErrInvalid)
	}
	if !validName(in.Name) {
		return fmt.Errorf("%w: name must be 1 to %d bytes, without control characters or surrounding spaces", ErrInvalid, maxName)
	}
	switch in.Transport {
	case "http":
		if in.Command != "" || len(in.Args) > 0 || len(in.Env) > 0 {
			return fmt.Errorf("%w: command, args and env are for stdio servers only", ErrInvalid)
		}
		if err := checkURL(in.URL); err != nil {
			return err
		}
		return checkPairs("headers", in.Headers, maxHeaders, maxHeaderName, true)
	case "stdio":
		if in.URL != "" || len(in.Headers) > 0 {
			return fmt.Errorf("%w: url and headers are for http servers only", ErrInvalid)
		}
		if in.Command == "" || len(in.Command) > maxCommand || !printable(in.Command) {
			return fmt.Errorf("%w: command must be a non-empty line of up to %d bytes", ErrInvalid, maxCommand)
		}
		if len(in.Args) > maxArgs {
			return fmt.Errorf("%w: args holds at most %d values", ErrInvalid, maxArgs)
		}
		for i, a := range in.Args {
			if len(a) > maxValue || !utf8.ValidString(a) || strings.ContainsRune(a, 0) {
				return fmt.Errorf("%w: args[%d] is not a valid value", ErrInvalid, i)
			}
		}
		return checkPairs("env", in.Env, maxEnv, maxHeaderName, false)
	}
	return fmt.Errorf(`%w: transport must be "http" or "stdio"`, ErrInvalid)
}

func validName(s string) bool {
	if s == "" || len(s) > maxName || !utf8.ValidString(s) || strings.TrimSpace(s) != s {
		return false
	}
	for _, r := range s {
		if unicode.IsControl(r) {
			return false
		}
	}
	return true
}

// printable is true when s has no control character (a command line or a header value).
func printable(s string) bool {
	for _, r := range s {
		if unicode.IsControl(r) && r != '\t' {
			return false
		}
	}
	return utf8.ValidString(s)
}

// checkURL accepts https to any host, and http only to a loopback host (D-019, as for the phone's
// entries). It refuses credentials, a query and a fragment: a secret goes in a header, not the URL.
func checkURL(raw string) error {
	if raw == "" || len(raw) > maxURL {
		return fmt.Errorf("%w: url must be set and at most %d bytes", ErrInvalid, maxURL)
	}
	u, err := url.Parse(raw)
	if err != nil || u.Hostname() == "" {
		return fmt.Errorf("%w: url is not valid", ErrInvalid)
	}
	if u.User != nil {
		return fmt.Errorf("%w: url must not carry credentials; use a header", ErrInvalid)
	}
	if strings.Contains(raw, "?") || u.Fragment != "" || u.RawQuery != "" {
		return fmt.Errorf("%w: url must not carry a query or fragment; use a header", ErrInvalid)
	}
	switch u.Scheme {
	case "https":
		return nil
	case "http":
		host := u.Hostname()
		if strings.EqualFold(host, "localhost") {
			return nil
		}
		if ip := net.ParseIP(host); ip != nil && ip.IsLoopback() {
			return nil
		}
	}
	return fmt.Errorf("%w: url must be https, or http to a loopback address", ErrInvalid)
}

// checkPairs checks header or environment pairs. Header values may not hold a line break.
func checkPairs(field string, pairs []Pair, maxCount, maxNameLen int, header bool) error {
	if len(pairs) > maxCount {
		return fmt.Errorf("%w: %s holds at most %d entries", ErrInvalid, field, maxCount)
	}
	for i, p := range pairs {
		if p.Name == "" || len(p.Name) > maxNameLen || !utf8.ValidString(p.Name) || strings.ContainsAny(p.Name, "\x00\r\n") {
			return fmt.Errorf("%w: %s[%d].name is not valid", ErrInvalid, field, i)
		}
		if header && strings.ContainsAny(p.Name, ": ") {
			return fmt.Errorf("%w: %s[%d].name is not valid", ErrInvalid, field, i)
		}
		if !header && strings.Contains(p.Name, "=") {
			return fmt.Errorf("%w: %s[%d].name is not valid", ErrInvalid, field, i)
		}
		if len(p.Value) > maxValue || !utf8.ValidString(p.Value) || strings.ContainsAny(p.Value, "\x00") || (header && strings.ContainsAny(p.Value, "\r\n")) {
			return fmt.Errorf("%w: %s[%d].value is not valid", ErrInvalid, field, i)
		}
	}
	return nil
}

func newID() (string, error) {
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("cannot make an id: %w", err)
	}
	return hex.EncodeToString(raw), nil
}
