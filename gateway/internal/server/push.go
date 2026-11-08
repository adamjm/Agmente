package server

import (
	"context"
	"regexp"
	"strings"
	"time"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/jsonv"
	"acpcode/gateway/internal/store"
)

// APNs device tokens are 32 bytes today and may be longer; accept 32 to 100 bytes as hex.
var pushTokenHex = regexp.MustCompile(`^[0-9a-fA-F]{64,200}$`)

// pushRegister stores the calling device's APNs token (D-052). The token is keyed by the
// authenticated identity and device, never by anything the phone sends, so a device can only
// set or remove its own. It is not logged, audited or returned.
func (s *Server) pushRegister(ctx context.Context, who audit.Who, params *jsonv.Value) (any, *rpcError) {
	tok, ok := params.Get("deviceToken").StringValue()
	if !ok || !pushTokenHex.MatchString(tok) || len(tok)%2 != 0 {
		return nil, invalidParams("deviceToken must be 64 to 200 hex digits")
	}
	env, ok := params.Get("environment").StringValue()
	if !ok || (env != "sandbox" && env != "production") {
		return nil, invalidParams("environment must be \"sandbox\" or \"production\"")
	}
	if who.Identity == "" || who.Device == "" {
		return nil, &rpcError{Code: rpcInternal, Message: "no device identity"}
	}
	err := s.store.SetPushToken(ctx, pushTokenRecord(who, strings.ToLower(tok), env))
	if err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot store token"}
	}
	s.audit.Log("push_registered", with(who, audit.Fields{}))
	return map[string]any{}, nil
}

// pushUnregister removes the calling device's token.
func (s *Server) pushUnregister(ctx context.Context, who audit.Who) (any, *rpcError) {
	removed, err := s.store.DeletePushToken(ctx, who.Identity, who.Device)
	if err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot remove token"}
	}
	if removed {
		s.audit.Log("push_unregistered", with(who, audit.Fields{}))
	}
	return map[string]any{}, nil
}

func pushTokenRecord(who audit.Who, token, env string) (t store.PushToken) {
	return store.PushToken{Identity: who.Identity, Device: who.Device, Token: token, Environment: env, Updated: time.Now().UTC().Format("2006-01-02T15:04:05.000Z")}
}
