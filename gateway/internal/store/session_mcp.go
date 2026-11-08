package store

import "context"

// SetSessionMCP replaces the set of gateway MCP servers a session enables (D-107). The rows are
// written in one transaction, so a reader never sees a half-written set.
func (s *Store) SetSessionMCP(ctx context.Context, sessionID string, serverIDs []string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `DELETE FROM session_mcp WHERE session_id = ?`, sessionID); err != nil {
		return err
	}
	for _, id := range serverIDs {
		if _, err := tx.ExecContext(ctx, `INSERT INTO session_mcp (session_id, server_id) VALUES (?, ?)`, sessionID, id); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// SessionMCP returns the ids of the gateway MCP servers a session enables, sorted. A session with
// no rows enables none.
func (s *Store) SessionMCP(ctx context.Context, sessionID string) ([]string, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT server_id FROM session_mcp WHERE session_id = ? ORDER BY server_id`, sessionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}
