package connector

import "testing"

// TestReleaseIsSetBeforeTheTurnIsReadable forces the window between inserting a turn in the registry
// and recording its release. A get_turn that finds the record in that window must find the release
// already set. Before the fix sendPrompt set rec.release after add, so the read saw nil (I2 report).
func TestReleaseIsSetBeforeTheTurnIsReadable(t *testing.T) {
	gw := baseFake()
	c, _ := testConnector(t, gw, defaultLimits())
	g := &Grant{ID: "g1", Scope: Scope{AllProjects: true}}

	ran := false
	nilRelease := false
	c.turns.inserted = func(rec *turnRecord) {
		ran = true
		found := c.turns.lookup(g.ID, rec.id)
		if found == nil || found.release == nil {
			nilRelease = true
		}
	}
	// The turn does not finish, so send_prompt returns "running" after the short wait.
	call(t, c, g, "send_prompt", map[string]any{"sessionId": "s1", "text": "hello"})
	if !ran {
		t.Fatal("the insert hook never ran, so the window was not exercised")
	}
	if nilRelease {
		t.Fatal("a turn was readable from the registry before its release was set")
	}
}
