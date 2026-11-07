package connector

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"sync"
	"time"
)

// Scope is what a grant may reach (C5): every project or a list, and optionally a list of sessions.
// Without a session list, every session in the listed projects is allowed.
type Scope struct {
	AllProjects bool
	Projects    []string
	HasSessions bool
	Sessions    []string
}

// Allows reports whether the scope reaches a project, and a session of it when sessionID is set.
func (s Scope) Allows(projectID, sessionID string) bool {
	if !s.AllProjects && !contains(s.Projects, projectID) {
		return false
	}
	if !s.HasSessions || sessionID == "" {
		return true
	}
	return contains(s.Sessions, sessionID)
}

// MarshalJSON writes the scope in the phone's form: "projects": "all" or a list, "sessions" when set.
func (s Scope) MarshalJSON() ([]byte, error) {
	type wire struct {
		Projects any       `json:"projects"`
		Sessions *[]string `json:"sessions,omitempty"`
	}
	w := wire{Projects: s.Projects}
	if s.AllProjects {
		w.Projects = "all"
	}
	if s.HasSessions {
		sessions := s.Sessions
		if sessions == nil {
			sessions = []string{}
		}
		w.Sessions = &sessions
	}
	return json.Marshal(w)
}

// UnmarshalJSON reads the phone's form back.
func (s *Scope) UnmarshalJSON(data []byte) error {
	var w struct {
		Projects json.RawMessage `json:"projects"`
		Sessions *[]string       `json:"sessions"`
	}
	if err := json.Unmarshal(data, &w); err != nil {
		return err
	}
	var out Scope
	var all string
	if err := json.Unmarshal(w.Projects, &all); err == nil && all == "all" {
		out.AllProjects = true
	} else if err := json.Unmarshal(w.Projects, &out.Projects); err != nil {
		return errors.New("scope.projects must be \"all\" or a list of project ids")
	}
	if w.Sessions != nil {
		out.HasSessions = true
		out.Sessions = *w.Sessions
	}
	*s = out
	return nil
}

// Grant is one approved connector pairing: its scope and the hash of its bearer token (D-003).
// The token itself is shown once, in the /token response, and is never stored.
type Grant struct {
	ID          string     `json:"grantId"`
	Label       string     `json:"label"`
	Scope       Scope      `json:"scope"`
	CreatedAt   time.Time  `json:"createdAt"`
	LastUsedAt  *time.Time `json:"lastUsedAt,omitempty"`
	ClientID    string     `json:"clientId"`
	Resource    string     `json:"resource"`
	TokenSHA256 string     `json:"tokenSha256,omitempty"`
}

// grantStore keeps the grants in memory and in one JSON file in the state directory (D-085 style:
// temp file in the same folder, O_EXCL, mode 0600, fsync, rename). It is the only place a grant's
// token hash is written; the SQLite store is not used (task D1, D-095).
type grantStore struct {
	path   string
	mu     sync.Mutex
	grants []*Grant // guarded by mu
}

type grantsFile struct {
	Version int      `json:"version"`
	Grants  []*Grant `json:"grants"`
}

func newGrantStore(path string) *grantStore { return &grantStore{path: path} }

// load reads the file. A missing file is an empty store.
func (s *grantStore) load() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	data, err := os.ReadFile(s.path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("cannot read the connector grants file: %w", err)
	}
	var f grantsFile
	if err := json.Unmarshal(data, &f); err != nil || f.Version != 1 {
		return errors.New("the connector grants file is not a version 1 grants file; move it aside to start with no grants")
	}
	s.grants = f.Grants
	return nil
}

// saveLocked writes the grants atomically. The caller holds mu.
func (s *grantStore) saveLocked() error {
	data, err := json.MarshalIndent(grantsFile{Version: 1, Grants: s.grants}, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	_ = os.Remove(tmp) // a leftover from a crash; O_EXCL needs the name free
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		_ = f.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, s.path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

// add stores a new grant and writes the file.
func (s *grantStore) add(g *Grant) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.grants = append(s.grants, g)
	if err := s.saveLocked(); err != nil {
		s.grants = s.grants[:len(s.grants)-1]
		return err
	}
	return nil
}

// setToken records the hash of a grant's token and writes the file.
func (s *grantStore) setToken(id, tokenHash string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	g := s.findLocked(id)
	if g == nil {
		return errNotFound
	}
	prev := g.TokenSHA256
	g.TokenSHA256 = tokenHash
	if err := s.saveLocked(); err != nil {
		g.TokenSHA256 = prev
		return err
	}
	return nil
}

// remove deletes a grant and writes the file. A revoked grant's token stops working at once.
func (s *grantStore) remove(id string) (*Grant, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var found *Grant
	next := make([]*Grant, 0, len(s.grants))
	for _, g := range s.grants {
		if g.ID == id {
			found = g
			continue
		}
		next = append(next, g)
	}
	if found == nil {
		return nil, errNotFound
	}
	prev := s.grants
	s.grants = next
	if err := s.saveLocked(); err != nil {
		s.grants = prev
		return nil, err
	}
	return found, nil
}

// find returns a copy of the grant with the id, or nil.
func (s *grantStore) find(id string) *Grant {
	s.mu.Lock()
	defer s.mu.Unlock()
	if g := s.findLocked(id); g != nil {
		c := *g
		return &c
	}
	return nil
}

func (s *grantStore) findLocked(id string) *Grant {
	for _, g := range s.grants {
		if g.ID == id {
			return g
		}
	}
	return nil
}

// list returns copies of every grant, in creation order.
func (s *grantStore) list() []Grant {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]Grant, 0, len(s.grants))
	for _, g := range s.grants {
		out = append(out, *g)
	}
	return out
}

// byToken returns a copy of the grant whose token hashes to token, or nil. The comparison is
// constant time over the hash.
func (s *grantStore) byToken(token string) *Grant {
	want := hashToken(token)
	s.mu.Lock()
	defer s.mu.Unlock()
	var hit *Grant
	for _, g := range s.grants {
		if g.TokenSHA256 != "" && subtle.ConstantTimeCompare([]byte(g.TokenSHA256), []byte(want)) == 1 {
			hit = g
		}
	}
	if hit == nil {
		return nil
	}
	c := *hit
	return &c
}

// touch records a use. The file is written at most once a minute per grant, so a busy client does
// not rewrite it on every request.
func (s *grantStore) touch(id string, now time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	g := s.findLocked(id)
	if g == nil || (g.LastUsedAt != nil && now.Sub(*g.LastUsedAt) < time.Minute) {
		return
	}
	prev := g.LastUsedAt
	g.LastUsedAt = &now
	if err := s.saveLocked(); err != nil {
		g.LastUsedAt = prev
	}
}

func contains(list []string, want string) bool {
	for _, s := range list {
		if s == want {
			return true
		}
	}
	return false
}
