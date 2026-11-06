// Payload building (PLAN 3.10, FR-23, NFR-11, D-038). Delivery is in apns.go.
//
// A payload holds the project name, the session id and the event type, and nothing else. The
// builder has no parameter for a prompt, a title or tool output, so none can reach a payload.
package push

import (
	"encoding/json"
	"errors"
	"strings"
	"unicode"
	"unicode/utf8"
)

// MaxBytes is NFR-11: a payload is at most 256 bytes.
const MaxBytes = 256

// Event is what happened.
type Event string

const (
	TurnEnded      Event = "turn_ended"
	ApprovalNeeded Event = "approval_needed"
	SessionFailed  Event = "session_failed"
)

var bodies = map[Event]string{
	TurnEnded:      "Turn finished",
	ApprovalNeeded: "Approval needed",
	SessionFailed:  "Session failed",
}

// ErrTooLong means the session id is too long for a payload of MaxBytes.
var ErrTooLong = errors.New("push payload cannot fit in 256 bytes")

type alert struct {
	Title string `json:"title"`
	Body  string `json:"body"`
}

type aps struct {
	Alert    alert  `json:"alert"`
	Sound    string `json:"sound"`
	ThreadID string `json:"thread-id"`
}

type payload struct {
	Aps       aps    `json:"aps"`
	SessionID string `json:"sessionId"`
	Event     Event  `json:"event"`
}

// Build returns the JSON payload for an event. The project name is shown as the title: control
// characters are removed, and it is cut on a character boundary, with an ellipsis, until the whole
// payload fits. An unknown event or an empty or oversized session id is an error.
func Build(event Event, projectName, sessionID string) ([]byte, error) {
	body, ok := bodies[event]
	if !ok {
		return nil, errors.New("unknown push event")
	}
	if sessionID == "" || !utf8.ValidString(sessionID) {
		return nil, errors.New("invalid session id")
	}
	name := clean(projectName)
	if name == "" {
		name = "Agmente"
	}
	p := payload{Aps: aps{Alert: alert{Body: body}, Sound: "default", ThreadID: sessionID}, SessionID: sessionID, Event: event}
	for {
		p.Aps.Alert.Title = name
		out, err := encode(p)
		if err != nil {
			return nil, err
		}
		if len(out) <= MaxBytes {
			return out, nil
		}
		if name == "…" {
			return nil, ErrTooLong
		}
		name = shorten(name)
	}
}

// encode marshals without HTML escaping (json.Marshal would turn < > & into < and grow it).
func encode(p payload) ([]byte, error) {
	var b strings.Builder
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(p); err != nil {
		return nil, err
	}
	return []byte(strings.TrimSuffix(b.String(), "\n")), nil
}

// clean drops control and format characters (newlines, bidi overrides) and trims spaces.
func clean(s string) string {
	if !utf8.ValidString(s) {
		s = strings.ToValidUTF8(s, "")
	}
	s = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) || unicode.Is(unicode.Cf, r) {
			return -1
		}
		return r
	}, s)
	return strings.TrimSpace(s)
}

// shorten removes the last character before a trailing ellipsis, and adds the ellipsis.
func shorten(s string) string {
	s = strings.TrimSuffix(s, "…")
	_, size := utf8.DecodeLastRuneInString(s)
	s = strings.TrimSpace(s[:len(s)-size])
	if s == "" {
		return "…"
	}
	return s + "…"
}
