package store

// Git credential profiles (D-105). The store holds metadata only: the token is in its own 0600 file
// under the state directory (credentials/<id>), never in this database.

import (
	"context"
	"database/sql"
	"errors"
)

// schemaV7 adds the git credential metadata table (D-105). No token column exists.
var schemaV7 = []string{
	`CREATE TABLE git_credentials (
		id TEXT PRIMARY KEY,
		name TEXT NOT NULL,
		host TEXT NOT NULL,
		created TEXT NOT NULL
	) WITHOUT ROWID`,
}

// GitCredential is the metadata of one credential profile.
type GitCredential struct {
	ID, Name, Host, Created string
}

// GitCredentials lists every profile, oldest first.
func (s *Store) GitCredentials(ctx context.Context) ([]GitCredential, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, name, host, created FROM git_credentials ORDER BY created, id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []GitCredential
	for rows.Next() {
		var c GitCredential
		if err := rows.Scan(&c.ID, &c.Name, &c.Host, &c.Created); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// GitCredentialByID returns one profile, or nil when there is none.
func (s *Store) GitCredentialByID(ctx context.Context, id string) (*GitCredential, error) {
	var c GitCredential
	err := s.db.QueryRowContext(ctx, `SELECT id, name, host, created FROM git_credentials WHERE id = ?`, id).
		Scan(&c.ID, &c.Name, &c.Host, &c.Created)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &c, nil
}

// SetGitCredential inserts a profile or replaces its name and host.
func (s *Store) SetGitCredential(ctx context.Context, c GitCredential) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO git_credentials (id, name, host, created) VALUES (?, ?, ?, ?)
		ON CONFLICT (id) DO UPDATE SET name = excluded.name, host = excluded.host`,
		c.ID, c.Name, c.Host, c.Created)
	return err
}

// DeleteGitCredential removes a profile and reports whether there was one.
func (s *Store) DeleteGitCredential(ctx context.Context, id string) (bool, error) {
	res, err := s.db.ExecContext(ctx, `DELETE FROM git_credentials WHERE id = ?`, id)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	return n > 0, err
}
