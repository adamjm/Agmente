package server

// Session titles. The agent names a session with `session_info_update`, but Bob sends that only after
// the first turn ends. Until then the gateway names the session from its first prompt, so the phone
// never lists a working session as "New Chat". The agent's own title replaces this one when it comes.

import (
	"context"
	"strings"
	"unicode/utf8"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/jsonv"
)

// maxProvisionalTitle is the longest provisional title, in characters, before the ellipsis.
const maxProvisionalTitle = 50

// promptTitle returns a short title from an ACP prompt: the first non-empty line of its text blocks,
// with runs of white space made single spaces, cut on a character boundary with an ellipsis. It
// returns "" when the prompt has no text.
func promptTitle(prompt *jsonv.Value) string {
	if prompt == nil || prompt.Kind != jsonv.Array {
		return ""
	}
	var text strings.Builder
	for _, b := range prompt.Arr {
		if b == nil || b.Kind != jsonv.Object {
			continue
		}
		if typ, _ := b.Get("type").StringValue(); typ != "text" {
			continue
		}
		t, _ := b.Get("text").StringValue()
		text.WriteString(t)
		text.WriteString("\n")
	}
	for _, line := range strings.Split(text.String(), "\n") {
		line = strings.Join(strings.Fields(line), " ")
		if line == "" {
			continue
		}
		if utf8.RuneCountInString(line) > maxProvisionalTitle {
			r := []rune(line)
			line = strings.TrimRight(string(r[:maxProvisionalTitle]), " ") + "…"
		}
		return strings.ToValidUTF8(line, "")
	}
	return ""
}

// nameFromPrompt gives a session that has no title one from its prompt. The store keeps any title the
// session already has, so only the first prompt names it, and the agent's own title still replaces it.
func (a *projectAgent) nameFromPrompt(sid string, prompt *jsonv.Value) {
	title := promptTitle(prompt)
	if title == "" {
		return
	}
	if err := a.s.store.SetSessionTitleIfEmpty(context.Background(), sid, title); err != nil {
		a.s.audit.Log("store_error", a.fields(audit.Fields{Reason: "session_title"}))
	}
}
