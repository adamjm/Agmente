package store

import "context"

// SessionRunners returns the runner recorded for each session of a project (projectID "" means every
// project), by session id. A session with none recorded is not in the map: it runs on its project's
// runner (D-125).
func (s *Store) SessionRunners(ctx context.Context, projectID string) (map[string]string, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT session_id, runner FROM sessions WHERE runner IS NOT NULL AND runner <> '' AND (?1 = '' OR project_id = ?1)`, projectID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var sid, runner string
		if err := rows.Scan(&sid, &runner); err != nil {
			return nil, err
		}
		out[sid] = runner
	}
	return out, rows.Err()
}
