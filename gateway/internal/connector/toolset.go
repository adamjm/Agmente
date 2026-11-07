package connector

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
)

// toolSpec is one connector tool (C7): its MCP definition and its handler. The handler gets the
// grant, which carries the scope, and the decoded arguments. It returns the tool's result, or an
// error whose text is the plain reason shown to the model.
type toolSpec struct {
	name        string
	description string
	schema      map[string]any
	call        func(c *Connector, g *Grant, args map[string]json.RawMessage) (any, error)
}

// toolSpecs is the tool table. The handlers are in tools.go (D-096).
var toolSpecs = []toolSpec{
	{
		name:        "list_projects",
		description: "List the projects this connector grant can reach.",
		schema:      objectSchema(nil),
		call: func(c *Connector, g *Grant, args map[string]json.RawMessage) (any, error) {
			return c.listProjects(g)
		},
	},
	{
		name:        "list_sessions",
		description: "List the sessions this grant can reach, optionally in one project.",
		schema:      objectSchema(map[string]any{"projectId": stringProp("Project id to list sessions for.")}),
		call: func(c *Connector, g *Grant, args map[string]json.RawMessage) (any, error) {
			return c.listSessions(g, args)
		},
	},
	{
		name:        "get_context",
		description: "A short summary of one session: status, usage, running tools, pending approvals, last stop reason.",
		schema:      objectSchema(map[string]any{"sessionId": stringProp("Session id.")}, "sessionId"),
		call: func(c *Connector, g *Grant, args map[string]json.RawMessage) (any, error) {
			return c.getContext(g, args)
		},
	},
	{
		name:        "send_prompt",
		description: "Send one prompt into a session as the source claude. Waits for the turn to end, up to the configured wait.",
		schema: objectSchema(map[string]any{
			"sessionId": stringProp("Session id."),
			"text":      stringProp("The prompt text."),
		}, "sessionId", "text"),
		call: func(c *Connector, g *Grant, args map[string]json.RawMessage) (any, error) {
			return c.sendPrompt(g, args)
		},
	},
	{
		name:        "get_turn",
		description: "The state of a turn that was still running when send_prompt returned.",
		schema:      objectSchema(map[string]any{"turnId": stringProp("Turn id from send_prompt.")}, "turnId"),
		call: func(c *Connector, g *Grant, args map[string]json.RawMessage) (any, error) {
			return c.getTurn(g, args)
		},
	},
}

func findTool(name string) *toolSpec {
	for i := range toolSpecs {
		if toolSpecs[i].name == name {
			return &toolSpecs[i]
		}
	}
	return nil
}

// toolList is the tools/list result.
func (c *Connector) toolList() map[string]any {
	out := make([]map[string]any, 0, len(toolSpecs))
	for _, t := range toolSpecs {
		out = append(out, map[string]any{"name": t.name, "description": t.description, "inputSchema": t.schema})
	}
	return map[string]any{"tools": out}
}

// sessionInScope resolves a session's project and checks the grant reaches it. An unknown session
// and one outside the scope get the same answer, so a grant cannot probe for other sessions.
func (c *Connector) sessionInScope(g *Grant, sessionID string) (string, error) {
	pid, err := c.opts.SessionProject(context.Background(), sessionID)
	if err != nil {
		return "", errors.New("cannot read sessions")
	}
	if pid == "" || !g.Scope.Allows(pid, sessionID) {
		return "", errors.New("sessionId is not in this grant's scope")
	}
	return pid, nil
}

func errOutsideScope(arg string) error {
	return fmt.Errorf("%s is not in this grant's scope", arg)
}

// stringArg reads a string argument. A missing required argument, or one that is not a string, is
// an error. An optional missing argument is "".
func stringArg(args map[string]json.RawMessage, key string, required bool) (string, error) {
	raw, ok := args[key]
	if !ok || string(raw) == "null" {
		if required {
			return "", fmt.Errorf("%s is required", key)
		}
		return "", nil
	}
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		return "", fmt.Errorf("%s must be a string", key)
	}
	if required && s == "" {
		return "", fmt.Errorf("%s must not be empty", key)
	}
	return s, nil
}

func objectSchema(props map[string]any, required ...string) map[string]any {
	if props == nil {
		props = map[string]any{}
	}
	s := map[string]any{"type": "object", "properties": props, "additionalProperties": false}
	if len(required) > 0 {
		s["required"] = required
	}
	return s
}

func stringProp(desc string) map[string]any {
	return map[string]any{"type": "string", "description": desc}
}
