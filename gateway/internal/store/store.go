// Package store is the gateway's SQLite database (D-023): the event log (FR-18) and, in later
// tasks, projects, sessions, read markers and approvals (PLAN phase 3 notes).
//
// It uses modernc.org/sqlite, a pure-Go SQLite, so the gateway stays one binary with no cgo.
// WAL with synchronous=NORMAL: a committed event survives a gateway crash or SIGKILL (NFR-7);
// on power loss the last transactions before the loss may be rolled back (SQLite WAL docs).
package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite" // registers the "sqlite" driver
)

// SchemaVersion is stored in PRAGMA user_version.
const SchemaVersion = 4

var schemaV1 = []string{
	`CREATE TABLE projects (
		id TEXT PRIMARY KEY,
		name TEXT NOT NULL,
		path TEXT NOT NULL UNIQUE,
		default_mode TEXT,
		created TEXT NOT NULL
	)`,
	`CREATE TABLE sessions (
		session_id TEXT PRIMARY KEY,
		project_id TEXT NOT NULL REFERENCES projects(id),
		title TEXT,
		status TEXT NOT NULL,
		last_activity TEXT NOT NULL,
		created TEXT NOT NULL
	)`,
	`CREATE TABLE events (
		session_id TEXT NOT NULL,
		seq INTEGER NOT NULL,
		ts TEXT NOT NULL,
		kind TEXT NOT NULL,
		message TEXT NOT NULL,
		PRIMARY KEY (session_id, seq)
	) WITHOUT ROWID`,
	`CREATE TABLE reads (
		identity TEXT NOT NULL,
		session_id TEXT NOT NULL,
		last_seen_seq INTEGER NOT NULL,
		PRIMARY KEY (identity, session_id)
	) WITHOUT ROWID`,
	`CREATE TABLE approvals (
		id TEXT PRIMARY KEY,
		session_id TEXT NOT NULL,
		agent_request_id TEXT NOT NULL,
		tool_call TEXT NOT NULL,
		options TEXT NOT NULL,
		since TEXT NOT NULL,
		answered_by TEXT,
		outcome TEXT
	)`,
}

// schemaV2 adds the turn snapshots (D-036).
var schemaV2 = []string{
	`CREATE TABLE snapshots (
		session_id TEXT NOT NULL,
		turn INTEGER NOT NULL,
		start_tree TEXT,
		end_tree TEXT,
		PRIMARY KEY (session_id, turn)
	) WITHOUT ROWID`,
}

// schemaV3 adds a project's own deny-list entries (D-050): a JSON array, NULL when none.
var schemaV3 = []string{
	`ALTER TABLE projects ADD COLUMN deny_paths TEXT`,
}

// schemaV4 adds the push device tokens (D-052): one token per identity and device.
var schemaV4 = []string{
	`CREATE TABLE push_tokens (
		identity TEXT NOT NULL,
		device TEXT NOT NULL,
		token TEXT NOT NULL,
		environment TEXT NOT NULL,
		updated TEXT NOT NULL,
		PRIMARY KEY (identity, device)
	) WITHOUT ROWID`,
}

// Store is one open database. It is safe for concurrent use.
type Store struct {
	db *sql.DB
}

// Event is one logged message for a session.
type Event struct {
	SessionID string
	Seq       int64
	TS        string
	Kind      string
	Message   string
}

// Open opens (and creates or migrates) the database at path.
func Open(path string) (*Store, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	q := url.Values{}
	for _, p := range []string{"journal_mode(WAL)", "synchronous(NORMAL)", "busy_timeout(5000)", "foreign_keys(ON)"} {
		q.Add("_pragma", p)
	}
	q.Set("_txlock", "immediate")
	db, err := sql.Open("sqlite", "file:"+path+"?"+q.Encode())
	if err != nil {
		return nil, err
	}
	// One connection: writes are serialized in the gateway, so SQLite never returns SQLITE_BUSY
	// between two of its own connections, and seq assignment cannot race.
	db.SetMaxOpenConns(1)
	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) migrate() error {
	var version int
	if err := s.db.QueryRow(`PRAGMA user_version`).Scan(&version); err != nil {
		return err
	}
	switch {
	case version == SchemaVersion:
		return nil
	case version > SchemaVersion:
		return fmt.Errorf("database schema %d is newer than this gateway (%d)", version, SchemaVersion)
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	steps := []struct {
		version int
		stmts   []string
	}{{1, schemaV1}, {2, schemaV2}, {3, schemaV3}, {4, schemaV4}}
	for _, step := range steps {
		if version >= step.version {
			continue
		}
		for _, stmt := range step.stmts {
			if _, err := tx.Exec(stmt); err != nil {
				return err
			}
		}
	}
	if _, err := tx.Exec(fmt.Sprintf(`PRAGMA user_version = %d`, SchemaVersion)); err != nil {
		return err
	}
	return tx.Commit()
}

// JournalMode returns SQLite's journal mode (for checks).
func (s *Store) JournalMode() (string, error) {
	var mode string
	err := s.db.QueryRow(`PRAGMA journal_mode`).Scan(&mode)
	return mode, err
}

// AppendEvent logs one message for a session and returns its seq: 1 for the first event of a
// session, then one more than the last (FR-18). The event is committed when this returns.
func (s *Store) AppendEvent(ctx context.Context, sessionID, kind string, message []byte) (int64, error) {
	if sessionID == "" {
		return 0, errors.New("empty session id")
	}
	var seq int64
	err := s.db.QueryRowContext(ctx, `
		INSERT INTO events (session_id, seq, ts, kind, message)
		SELECT ?1, COALESCE(MAX(seq), 0) + 1, ?2, ?3, ?4 FROM events WHERE session_id = ?1
		RETURNING seq`,
		sessionID, time.Now().UTC().Format("2006-01-02T15:04:05.000Z"), kind, string(message)).Scan(&seq)
	return seq, err
}

// HeadSeq is the last seq of a session, or 0 when it has no events.
func (s *Store) HeadSeq(ctx context.Context, sessionID string) (int64, error) {
	var seq int64
	err := s.db.QueryRowContext(ctx, `SELECT COALESCE(MAX(seq), 0) FROM events WHERE session_id = ?`, sessionID).Scan(&seq)
	return seq, err
}

// EventsAfter calls fn for each event of a session with seq > afterSeq, in seq order, up to
// upToSeq when it is above 0. It stops at the first error from fn.
func (s *Store) EventsAfter(ctx context.Context, sessionID string, afterSeq, upToSeq int64, fn func(Event) error) error {
	if upToSeq <= 0 {
		upToSeq = 1<<62 - 1
	}
	rows, err := s.db.QueryContext(ctx,
		`SELECT seq, ts, kind, message FROM events WHERE session_id = ? AND seq > ? AND seq <= ? ORDER BY seq`,
		sessionID, afterSeq, upToSeq)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		e := Event{SessionID: sessionID}
		if err := rows.Scan(&e.Seq, &e.TS, &e.Kind, &e.Message); err != nil {
			return err
		}
		if err := fn(e); err != nil {
			return err
		}
	}
	return rows.Err()
}

// Project is one registered project (FR-17).
type Project struct {
	ID          string
	Name        string
	Path        string // realpath on the gateway host
	DefaultMode string // "" when unset
	Created     string
	DenyPaths   []string // additions to the secret deny-list (D-050); the built-ins always apply
}

// ErrDuplicatePath means a project with the same path is already registered.
var ErrDuplicatePath = errors.New("a project with this path is already registered")

// CreateProject inserts a project. It returns ErrDuplicatePath when the path is taken.
func (s *Store) CreateProject(ctx context.Context, p Project) error {
	var mode any
	if p.DefaultMode != "" {
		mode = p.DefaultMode
	}
	var deny any
	if len(p.DenyPaths) > 0 {
		b, err := json.Marshal(p.DenyPaths)
		if err != nil {
			return err
		}
		deny = string(b)
	}
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO projects (id, name, path, default_mode, created, deny_paths) VALUES (?, ?, ?, ?, ?, ?)`,
		p.ID, p.Name, p.Path, mode, p.Created, deny)
	if err != nil && strings.Contains(err.Error(), "UNIQUE constraint failed: projects.path") {
		return ErrDuplicatePath
	}
	return err
}

// Projects lists every project, oldest first.
func (s *Store) Projects(ctx context.Context) ([]Project, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, name, path, COALESCE(default_mode, ''), created, COALESCE(deny_paths, '') FROM projects ORDER BY created, id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Project{}
	for rows.Next() {
		var p Project
		var deny string
		if err := rows.Scan(&p.ID, &p.Name, &p.Path, &p.DefaultMode, &p.Created, &deny); err != nil {
			return nil, err
		}
		if p.DenyPaths, err = parseDeny(deny); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

// ProjectByPath returns the project registered at path, or nil.
func (s *Store) ProjectByPath(ctx context.Context, path string) (*Project, error) {
	var p Project
	var deny string
	err := s.db.QueryRowContext(ctx, `SELECT id, name, path, COALESCE(default_mode, ''), created, COALESCE(deny_paths, '') FROM projects WHERE path = ?`, path).
		Scan(&p.ID, &p.Name, &p.Path, &p.DefaultMode, &p.Created, &deny)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if p.DenyPaths, err = parseDeny(deny); err != nil {
		return nil, err
	}
	return &p, nil
}

// ProjectByID returns the project with this id, or nil.
func (s *Store) ProjectByID(ctx context.Context, id string) (*Project, error) {
	var p Project
	var deny string
	err := s.db.QueryRowContext(ctx, `SELECT id, name, path, COALESCE(default_mode, ''), created, COALESCE(deny_paths, '') FROM projects WHERE id = ?`, id).
		Scan(&p.ID, &p.Name, &p.Path, &p.DefaultMode, &p.Created, &deny)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if p.DenyPaths, err = parseDeny(deny); err != nil {
		return nil, err
	}
	return &p, nil
}

// RecordSession notes that a session belongs to a project. A new session starts "idle"; an
// existing one keeps its status and gets a new last activity. It returns an error if the session
// is already recorded for another project.
func (s *Store) RecordSession(ctx context.Context, sessionID, projectID string) error {
	now := time.Now().UTC().Format("2006-01-02T15:04:05.000Z")
	res, err := s.db.ExecContext(ctx, `
		INSERT INTO sessions (session_id, project_id, status, last_activity, created) VALUES (?1, ?2, 'idle', ?3, ?3)
		ON CONFLICT (session_id) DO UPDATE SET last_activity = ?3 WHERE project_id = ?2`,
		sessionID, projectID, now)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrSessionElsewhere
	}
	return nil
}

// ErrSessionElsewhere means the session is recorded for another project.
var ErrSessionElsewhere = errors.New("the session belongs to another project")

// SessionProject returns the project id of a recorded session, or "".
func (s *Store) SessionProject(ctx context.Context, sessionID string) (string, error) {
	var id string
	err := s.db.QueryRowContext(ctx, `SELECT project_id FROM sessions WHERE session_id = ?`, sessionID).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return id, err
}

// SetSessionTitle records the title the agent gave a session.
func (s *Store) SetSessionTitle(ctx context.Context, sessionID, title string) error {
	_, err := s.db.ExecContext(ctx, `UPDATE sessions SET title = ? WHERE session_id = ?`, title, sessionID)
	return err
}

// SetSessionStatus records how a session's last turn ended: "idle" or "error".
func (s *Store) SetSessionStatus(ctx context.Context, sessionID, status string) error {
	_, err := s.db.ExecContext(ctx, `UPDATE sessions SET status = ? WHERE session_id = ?`, status, sessionID)
	return err
}

// DeleteSession removes a session, its events and its read markers.
func (s *Store) DeleteSession(ctx context.Context, sessionID string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, q := range []string{
		`DELETE FROM events WHERE session_id = ?`,
		`DELETE FROM reads WHERE session_id = ?`,
		`DELETE FROM snapshots WHERE session_id = ?`,
		`DELETE FROM sessions WHERE session_id = ?`,
	} {
		if _, err := tx.ExecContext(ctx, q, sessionID); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// SessionRow is one session in the index (FR-21).
type SessionRow struct {
	SessionID    string
	ProjectID    string
	Title        *string
	Status       string // stored: "idle" or "error"
	LastActivity string
	HeadSeq      int64
	Unread       int64
}

// SessionIndex lists the recorded sessions, newest activity first, for one project or (projectID
// "") all. Unread counts the turns that ended after the identity's read marker. Last activity is
// the time of the last event, or of the last record when that is later.
func (s *Store) SessionIndex(ctx context.Context, identity, projectID string) ([]SessionRow, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT s.session_id, s.project_id, s.title, s.status,
		       MAX(s.last_activity, COALESCE((SELECT ts FROM events e WHERE e.session_id = s.session_id ORDER BY seq DESC LIMIT 1), '')) AS activity,
		       COALESCE((SELECT MAX(seq) FROM events e WHERE e.session_id = s.session_id), 0),
		       (SELECT COUNT(*) FROM events e WHERE e.session_id = s.session_id AND e.kind = 'turn_ended'
		          AND e.seq > COALESCE((SELECT last_seen_seq FROM reads r WHERE r.identity = ?1 AND r.session_id = s.session_id), 0))
		FROM sessions s
		WHERE ?2 = '' OR s.project_id = ?2
		ORDER BY activity DESC, s.session_id`, identity, projectID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []SessionRow{}
	for rows.Next() {
		var r SessionRow
		var title sql.NullString
		if err := rows.Scan(&r.SessionID, &r.ProjectID, &title, &r.Status, &r.LastActivity, &r.HeadSeq, &r.Unread); err != nil {
			return nil, err
		}
		if title.Valid {
			t := title.String
			r.Title = &t
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// MarkRead moves an identity's read marker for a session forward to seq, capped at the session's
// head. It never moves back. It returns the marker after the change.
func (s *Store) MarkRead(ctx context.Context, identity, sessionID string, seq int64) (int64, error) {
	var marker int64
	err := s.db.QueryRowContext(ctx, `
		INSERT INTO reads (identity, session_id, last_seen_seq)
		VALUES (?1, ?2, MIN(?3, (SELECT COALESCE(MAX(seq), 0) FROM events WHERE session_id = ?2)))
		ON CONFLICT (identity, session_id) DO UPDATE SET last_seen_seq = MAX(last_seen_seq, excluded.last_seen_seq)
		RETURNING last_seen_seq`, identity, sessionID, seq).Scan(&marker)
	return marker, err
}

// Approval is one permission request the gateway relayed (FR-22, D-031).
type Approval struct {
	ID, SessionID, AgentRequestID, ToolCall, Options, Since string
	AnsweredBy, Outcome                                     string // "" while open
}

// InsertApproval records an open approval.
func (s *Store) InsertApproval(ctx context.Context, a Approval) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO approvals (id, session_id, agent_request_id, tool_call, options, since) VALUES (?, ?, ?, ?, ?, ?)`,
		a.ID, a.SessionID, a.AgentRequestID, a.ToolCall, a.Options, a.Since)
	return err
}

// AnswerApproval records who or what closed an open approval, and the outcome sent to the agent.
func (s *Store) AnswerApproval(ctx context.Context, id, answeredBy, outcome string) error {
	_, err := s.db.ExecContext(ctx,
		`UPDATE approvals SET answered_by = ?, outcome = ? WHERE id = ? AND answered_by IS NULL`, answeredBy, outcome, id)
	return err
}

// ApprovalByID returns an approval, or nil.
func (s *Store) ApprovalByID(ctx context.Context, id string) (*Approval, error) {
	var a Approval
	err := s.db.QueryRowContext(ctx, `
		SELECT id, session_id, agent_request_id, tool_call, options, since, COALESCE(answered_by, ''), COALESCE(outcome, '')
		FROM approvals WHERE id = ?`, id).
		Scan(&a.ID, &a.SessionID, &a.AgentRequestID, &a.ToolCall, &a.Options, &a.Since, &a.AnsweredBy, &a.Outcome)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &a, nil
}

// CloseOpenApprovals marks every open approval as closed by reason. A gateway that starts has no
// agent, so no approval from before can still be answered.
func (s *Store) CloseOpenApprovals(ctx context.Context, reason string) (int64, error) {
	res, err := s.db.ExecContext(ctx, `UPDATE approvals SET answered_by = ?, outcome = '' WHERE answered_by IS NULL`, reason)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// MaxApprovalSeq is the highest n in an approval id "agmente-perm-<n>", or 0, so ids stay unique
// across gateway restarts.
func (s *Store) MaxApprovalSeq(ctx context.Context) (int64, error) {
	var n int64
	err := s.db.QueryRowContext(ctx,
		`SELECT COALESCE(MAX(CAST(SUBSTR(id, 14) AS INTEGER)), 0) FROM approvals WHERE id LIKE 'agmente-perm-%'`).Scan(&n)
	return n, err
}

// TurnCount is the number of turns logged for a session: the number of its turn_started events.
func (s *Store) TurnCount(ctx context.Context, sessionID string) (int64, error) {
	var n int64
	err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM events WHERE session_id = ? AND kind = 'turn_started'`, sessionID).Scan(&n)
	return n, err
}

// SetStartTree and SetEndTree record the git tree of the project at a turn's start and end (D-036).
func (s *Store) SetStartTree(ctx context.Context, sessionID string, turn int64, tree string) error {
	_, err := s.db.ExecContext(ctx, `INSERT INTO snapshots (session_id, turn, start_tree) VALUES (?, ?, ?)
		ON CONFLICT (session_id, turn) DO UPDATE SET start_tree = excluded.start_tree`, sessionID, turn, tree)
	return err
}

func (s *Store) SetEndTree(ctx context.Context, sessionID string, turn int64, tree string) error {
	_, err := s.db.ExecContext(ctx, `INSERT INTO snapshots (session_id, turn, end_tree) VALUES (?, ?, ?)
		ON CONFLICT (session_id, turn) DO UPDATE SET end_tree = excluded.end_tree`, sessionID, turn, tree)
	return err
}

// Snapshot returns a turn's trees; empty strings when one was not taken. found is false when the
// turn has no row.
func (s *Store) Snapshot(ctx context.Context, sessionID string, turn int64) (start, end string, found bool, err error) {
	var a, b sql.NullString
	err = s.db.QueryRowContext(ctx, `SELECT start_tree, end_tree FROM snapshots WHERE session_id = ? AND turn = ?`, sessionID, turn).Scan(&a, &b)
	if errors.Is(err, sql.ErrNoRows) {
		return "", "", false, nil
	}
	return a.String, b.String, err == nil, err
}

// parseDeny reads a stored deny_paths value ("" when none).
func parseDeny(v string) ([]string, error) {
	if v == "" {
		return nil, nil
	}
	var out []string
	if err := json.Unmarshal([]byte(v), &out); err != nil {
		return nil, fmt.Errorf("stored denyPaths: %w", err)
	}
	return out, nil
}

// PushToken is a device's APNs token (D-052).
type PushToken struct {
	Identity, Device, Token, Environment, Updated string
}

// SetPushToken stores a device's token, replacing any earlier one for the same identity and device.
func (s *Store) SetPushToken(ctx context.Context, t PushToken) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO push_tokens (identity, device, token, environment, updated) VALUES (?, ?, ?, ?, ?)
		ON CONFLICT (identity, device) DO UPDATE SET token = excluded.token, environment = excluded.environment, updated = excluded.updated`,
		t.Identity, t.Device, t.Token, t.Environment, t.Updated)
	return err
}

// DeletePushToken removes a device's token and reports whether there was one.
func (s *Store) DeletePushToken(ctx context.Context, identity, device string) (bool, error) {
	res, err := s.db.ExecContext(ctx, `DELETE FROM push_tokens WHERE identity = ? AND device = ?`, identity, device)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n > 0, err
}

// PushTokens lists the tokens of an identity (delivery, 3.11, reads this).
func (s *Store) PushTokens(ctx context.Context, identity string) ([]PushToken, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT identity, device, token, environment, updated FROM push_tokens WHERE identity = ? ORDER BY device`, identity)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []PushToken
	for rows.Next() {
		var t PushToken
		if err := rows.Scan(&t.Identity, &t.Device, &t.Token, &t.Environment, &t.Updated); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}
