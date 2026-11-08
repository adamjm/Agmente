package connector

import (
	"errors"
	"fmt"
	"sync"
	"time"

	"acpcode/gateway/internal/config"
)

// limits holds the connector's running counts (C6): prompts per grant in the last hour, the running
// turn of each session, and the number of turns running overall.
type limits struct {
	cfg config.ConnectorLimits
	now func() time.Time

	mu      sync.Mutex
	prompts map[string][]time.Time // grant id -> times of admitted prompts in the last hour; guarded by mu
	turns   map[string]bool        // session id -> a turn is running; guarded by mu
}

func newLimits(cfg config.ConnectorLimits) *limits {
	return &limits{cfg: cfg, now: time.Now, prompts: map[string][]time.Time{}, turns: map[string]bool{}}
}

// admitPrompt checks a prompt of size bytes from a grant against maxPromptBytes and promptsPerHour.
// Each attempt that passes the scope check counts, whether or not the turn then starts, so a grant
// cannot retry its way around the hourly limit.
func (l *limits) admitPrompt(grantID string, size int) error {
	if int64(size) > l.cfg.MaxPromptBytes {
		return fmt.Errorf("text is larger than %d bytes (connector limit maxPromptBytes)", l.cfg.MaxPromptBytes)
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	kept := l.prompts[grantID][:0]
	for _, t := range l.prompts[grantID] {
		if now.Sub(t) < time.Hour {
			kept = append(kept, t)
		}
	}
	if int64(len(kept)) >= l.cfg.PromptsPerHour {
		l.prompts[grantID] = kept
		return fmt.Errorf("prompt limit reached: %d prompts per hour for this grant (connector limit promptsPerHour)", l.cfg.PromptsPerHour)
	}
	l.prompts[grantID] = append(kept, now)
	return nil
}

// startTurn reserves the turn slot of a session: one running turn per session and at most
// maxConcurrentTurns overall. The returned func releases the slot; it is safe to call twice.
func (l *limits) startTurn(sessionID string) (func(), error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.turns[sessionID] {
		return nil, errors.New("this session already has a turn running")
	}
	if int64(len(l.turns)) >= l.cfg.MaxConcurrentTurns {
		return nil, fmt.Errorf("too many turns are running (connector limit maxConcurrentTurns is %d)", l.cfg.MaxConcurrentTurns)
	}
	l.turns[sessionID] = true
	var once sync.Once
	return func() {
		once.Do(func() {
			l.mu.Lock()
			delete(l.turns, sessionID)
			l.mu.Unlock()
		})
	}, nil
}
