package server

// The agent's usage for a session (C1, D-092). The agent sends `session/update` with
// sessionUpdate "usage_update": used and size are tokens, cost is the session's cumulative cost. The
// gateway keeps the last value per session and puts it on the sessions index. The event log is not
// changed: the update is still logged as before. Nothing is estimated.

import (
	"context"

	"agmente/gateway/internal/audit"
	"agmente/gateway/internal/jsonv"
	"agmente/gateway/internal/store"
)

// maxCurrencyLen is the longest currency code kept (ISO 4217 codes are three letters).
const maxCurrencyLen = 8

// usageFromUpdate reads a usage_update. It returns false unless used and size are both whole,
// non-negative numbers: a partial update is not stored. A cost is kept only when its amount is a
// finite, non-negative number; its currency is optional.
func usageFromUpdate(u *jsonv.Value) (store.Usage, bool) {
	used, okUsed := u.Get("used").Int()
	size, okSize := u.Get("size").Int()
	if !okUsed || !okSize || used < 0 || size < 0 {
		return store.Usage{}, false
	}
	out := store.Usage{Used: used, Size: size}
	if cost := u.Get("cost"); cost != nil && cost.Kind == jsonv.Object {
		if amount, ok := cost.Get("amount").Float(); ok && amount >= 0 {
			out.CostAmount = &amount
			if cur, ok := cost.Get("currency").StringValue(); ok && cur != "" && len(cur) <= maxCurrencyLen {
				out.CostCurrency = &cur
			}
		}
	}
	return out, true
}

// recordUsage stores a session's usage_update. It replaces the stored value, cost included: the
// last update is the agent's current figure. A refused update changes nothing.
func (a *projectAgent) recordUsage(sid string, u *jsonv.Value) {
	usage, ok := usageFromUpdate(u)
	if !ok {
		return
	}
	if err := a.s.store.SetUsage(context.Background(), sid, usage); err != nil {
		a.s.audit.Log("store_error", a.fields(audit.Fields{Reason: "session_usage"}))
	}
}
