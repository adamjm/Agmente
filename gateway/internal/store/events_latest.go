package store

import (
	"context"
	"database/sql"
	"errors"
)

// LatestEvent returns the newest event of one kind in a session, and false when it has none. It is
// a read of the existing events table (D-096): the connector uses it for the last turn's start and
// stop reason. The table is not changed.
func (s *Store) LatestEvent(ctx context.Context, sessionID, kind string) (Event, bool, error) {
	e := Event{SessionID: sessionID}
	err := s.db.QueryRowContext(ctx,
		`SELECT seq, ts, kind, message FROM events WHERE session_id = ? AND kind = ? ORDER BY seq DESC LIMIT 1`,
		sessionID, kind).Scan(&e.Seq, &e.TS, &e.Kind, &e.Message)
	if errors.Is(err, sql.ErrNoRows) {
		return Event{}, false, nil
	}
	if err != nil {
		return Event{}, false, err
	}
	return e, true, nil
}
