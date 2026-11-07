package audit

// Skill events (FR-43, D-087). A skill line carries the project, the skill's name and its byte
// count, and never the content. It is a separate function so the shared Log line stays as it is.

import (
	"strconv"

	"agmente/gateway/internal/jsonv"
)

// LogSkill writes one line: {"ts":..., "event":..., identity, device, client, conn, project,
// skill, bytes}. Unset fields are left out, as in Log.
func (l *Logger) LogSkill(event string, f Fields, skill string, bytes int) {
	buf := make([]byte, 0, 256)
	buf = append(buf, `{"ts":`...)
	buf = jsonv.AppendString(buf, l.now().UTC().Format("2006-01-02T15:04:05.000Z"))
	buf = append(buf, `,"event":`...)
	buf = jsonv.AppendString(buf, event)
	str := func(key, value string) {
		if value != "" {
			buf = append(buf, `,"`...)
			buf = append(buf, key...)
			buf = append(buf, `":`...)
			buf = jsonv.AppendString(buf, value)
		}
	}
	str("identity", f.Identity)
	str("device", f.Device)
	str("client", f.Client)
	if f.Conn != 0 {
		buf = append(buf, `,"conn":`...)
		buf = strconv.AppendInt(buf, int64(f.Conn), 10)
	}
	str("project", f.Project)
	str("skill", skill)
	buf = append(buf, `,"bytes":`...)
	buf = strconv.AppendInt(buf, int64(bytes), 10)
	buf = append(buf, '}', '\n')
	l.mu.Lock()
	defer l.mu.Unlock()
	_, _ = l.out.Write(buf)
}
