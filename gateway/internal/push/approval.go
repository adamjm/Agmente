// Approval payloads (D-111). An approval says what is being approved: the body is
// "Approval needed: <summary>", where the summary is the tool call's title, with a verb for its kind.
// The summary is text from the agent, so it is cleaned, collapsed and cut before it is sent. The
// builder takes a summary string and nothing else from the request: no prompt, tool output, file
// content or raw arguments.
package push

import (
	"errors"
	"strings"
	"unicode"
	"unicode/utf8"
)

// ApprovalMaxBytes is the size limit for an approval payload (D-111, amends NFR-11 for approvals).
const ApprovalMaxBytes = 512

// approvalBody is the body with no summary, as before D-111.
const approvalBody = "Approval needed"

// approvalCategory is the APNs category. The app registers it with no actions (D-009).
const approvalCategory = "APPROVAL"

// summaryMax is the most characters a summary keeps, the ellipsis included.
const summaryMax = 80

// verbs maps a tool call kind to the verb shown in front of its title. An unknown kind has no verb.
var verbs = map[string]string{
	"execute": "Run",
	"edit":    "Edit",
	"delete":  "Delete",
	"read":    "Read",
	"fetch":   "Fetch",
	"move":    "Move",
}

// Summary returns the text an approval shows for a tool call: the title with the verb for its kind
// in front, such as "Run: npm test". With no known kind it is the title alone. A title that already
// starts with the verb is not given it again ("Run echo", not "Run: Run echo"). An empty title gives
// "". The result is not cut: BuildApproval cleans and cuts it.
func Summary(title, kind string) string {
	t := squash(title)
	if t == "" {
		return ""
	}
	verb := verbs[kind]
	if verb == "" {
		return t
	}
	if first, _, _ := strings.Cut(t, " "); strings.EqualFold(first, verb) {
		return t
	}
	return verb + ": " + t
}

// BuildApproval returns the JSON payload for an approval. The title is the project name, as in
// Build. The body is "Approval needed: <summary>", or "Approval needed" when the summary is empty.
// The summary is cleaned, its whitespace collapsed, and it is cut to 80 characters. If the payload
// is over ApprovalMaxBytes, the summary is shortened first, then the project name. An empty or
// non-UTF-8 session id is an error, and so is one too long to fit.
func BuildApproval(projectName, sessionID, summary string) ([]byte, error) {
	if sessionID == "" || !utf8.ValidString(sessionID) {
		return nil, errors.New("invalid session id")
	}
	name := clean(projectName)
	if name == "" {
		name = "ACP Code"
	}
	sum := cutSummary(squash(summary))
	for {
		body := approvalBody
		if sum != "" {
			body += ": " + sum
		}
		p := payload{
			Aps: aps{
				Alert:    alert{Title: name, Body: body},
				Sound:    "default",
				Category: approvalCategory,
				ThreadID: sessionID,
			},
			SessionID: sessionID,
			Event:     ApprovalNeeded,
		}
		out, err := encode(p)
		if err != nil {
			return nil, err
		}
		if len(out) <= ApprovalMaxBytes {
			return out, nil
		}
		if sum != "" {
			if sum == "…" {
				sum = ""
			} else {
				sum = shorten(sum)
			}
			continue
		}
		if name == "…" {
			return nil, ErrTooLong
		}
		name = shorten(name)
	}
}

// squash makes a summary one line: every space, tab and newline becomes a space, control and format
// characters are dropped, and runs of spaces collapse to one.
func squash(s string) string {
	if !utf8.ValidString(s) {
		s = strings.ToValidUTF8(s, "")
	}
	s = strings.Map(func(r rune) rune {
		if unicode.IsSpace(r) {
			return ' '
		}
		if unicode.IsControl(r) || unicode.Is(unicode.Cf, r) {
			return -1
		}
		return r
	}, s)
	return strings.Join(strings.Fields(s), " ")
}

// cutSummary keeps the first 79 characters of a summary longer than 80, then adds an ellipsis.
func cutSummary(s string) string {
	if utf8.RuneCountInString(s) <= summaryMax {
		return s
	}
	r := []rune(s)[:summaryMax-1]
	return strings.TrimRight(string(r), " ") + "…"
}
