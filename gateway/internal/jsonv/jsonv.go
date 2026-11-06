// Package jsonv parses JSON into an order-preserving tree and writes it back as one compact line.
//
// It matches JavaScript's JSON.parse then JSON.stringify where that matters to the gateway:
// object keys keep the position of their first occurrence and take the value of their last one,
// and key lookup is exact (encoding/json matches struct fields case-insensitively, which would let
// {"METHOD": ...} pass as "method"). Output never contains a raw line break: control characters,
// U+2028 and U+2029 are always escaped, because Node's readline ends a line at each of them.
// Numbers keep their literal text, so large integer ids are not rounded.
package jsonv

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"strconv"
	"unicode/utf8"
)

type Kind int

const (
	Null Kind = iota
	Bool
	Number
	String
	Array
	Object
)

// Value is one parsed JSON value.
type Value struct {
	Kind Kind
	B    bool
	Num  string // literal text of a number
	Str  string
	Arr  []*Value
	Keys []string // object keys in first-occurrence order
	Obj  map[string]*Value
}

var ErrInvalid = errors.New("invalid JSON")

// Parse parses exactly one JSON value. Trailing data, including a second value, is an error.
func Parse(data []byte) (*Value, error) {
	if !json.Valid(data) {
		return nil, ErrInvalid
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	v, err := parseValue(dec)
	if err != nil {
		return nil, err
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, ErrInvalid
	}
	return v, nil
}

func parseValue(dec *json.Decoder) (*Value, error) {
	tok, err := dec.Token()
	if err != nil {
		return nil, ErrInvalid
	}
	switch t := tok.(type) {
	case nil:
		return &Value{Kind: Null}, nil
	case bool:
		return &Value{Kind: Bool, B: t}, nil
	case json.Number:
		return &Value{Kind: Number, Num: t.String()}, nil
	case string:
		return &Value{Kind: String, Str: t}, nil
	case json.Delim:
		switch t {
		case '[':
			v := &Value{Kind: Array, Arr: []*Value{}}
			for dec.More() {
				item, err := parseValue(dec)
				if err != nil {
					return nil, err
				}
				v.Arr = append(v.Arr, item)
			}
			if _, err := dec.Token(); err != nil {
				return nil, ErrInvalid
			}
			return v, nil
		case '{':
			v := &Value{Kind: Object, Obj: map[string]*Value{}}
			for dec.More() {
				kt, err := dec.Token()
				if err != nil {
					return nil, ErrInvalid
				}
				key, ok := kt.(string)
				if !ok {
					return nil, ErrInvalid
				}
				item, err := parseValue(dec)
				if err != nil {
					return nil, err
				}
				if _, seen := v.Obj[key]; !seen {
					v.Keys = append(v.Keys, key)
				}
				v.Obj[key] = item
			}
			if _, err := dec.Token(); err != nil {
				return nil, ErrInvalid
			}
			return v, nil
		}
	}
	return nil, ErrInvalid
}

// Get returns the member `key` of an object, or nil when v is not an object or has no such key.
func (v *Value) Get(key string) *Value {
	if v == nil || v.Kind != Object {
		return nil
	}
	return v.Obj[key]
}

// IsNull is true for a missing value (nil) and for JSON null: JavaScript's `x == null`.
func (v *Value) IsNull() bool { return v == nil || v.Kind == Null }

// StringValue returns the string and true when v is a JSON string.
func (v *Value) StringValue() (string, bool) {
	if v == nil || v.Kind != String {
		return "", false
	}
	return v.Str, true
}

// Float returns the number as float64 and true when v is a finite JSON number.
func (v *Value) Float() (float64, bool) {
	if v == nil || v.Kind != Number {
		return 0, false
	}
	f, err := strconv.ParseFloat(v.Num, 64)
	if err != nil {
		return 0, false // out of range: JavaScript would see Infinity, which is not an integer
	}
	return f, true
}

// Int returns the value as an int and true when it is a number with no fractional part
// (JavaScript's Number.isInteger).
func (v *Value) Int() (int64, bool) {
	f, ok := v.Float()
	if !ok || f != float64(int64(f)) {
		return 0, false
	}
	return int64(f), true
}

// Marshal writes v as one compact line of JSON.
func (v *Value) Marshal() []byte { return v.AppendTo(nil) }

// AppendTo appends v as compact JSON to buf.
func (v *Value) AppendTo(buf []byte) []byte {
	switch v.Kind {
	case Null:
		return append(buf, "null"...)
	case Bool:
		if v.B {
			return append(buf, "true"...)
		}
		return append(buf, "false"...)
	case Number:
		return append(buf, v.Num...)
	case String:
		return AppendString(buf, v.Str)
	case Array:
		buf = append(buf, '[')
		for i, item := range v.Arr {
			if i > 0 {
				buf = append(buf, ',')
			}
			buf = item.AppendTo(buf)
		}
		return append(buf, ']')
	default:
		buf = append(buf, '{')
		for i, key := range v.Keys {
			if i > 0 {
				buf = append(buf, ',')
			}
			buf = AppendString(buf, key)
			buf = append(buf, ':')
			buf = v.Obj[key].AppendTo(buf)
		}
		return append(buf, '}')
	}
}

const hex = "0123456789abcdef"

// AppendString appends s as a JSON string. It escapes quote, backslash, every control character,
// U+2028 and U+2029, and replaces invalid UTF-8 with U+FFFD. Everything else is written as UTF-8.
func AppendString(buf []byte, s string) []byte {
	buf = append(buf, '"')
	for i := 0; i < len(s); {
		c := s[i]
		if c < utf8.RuneSelf {
			switch {
			case c == '"':
				buf = append(buf, '\\', '"')
			case c == '\\':
				buf = append(buf, '\\', '\\')
			case c == '\n':
				buf = append(buf, '\\', 'n')
			case c == '\r':
				buf = append(buf, '\\', 'r')
			case c == '\t':
				buf = append(buf, '\\', 't')
			case c == '\b':
				buf = append(buf, '\\', 'b')
			case c == '\f':
				buf = append(buf, '\\', 'f')
			case c < 0x20 || c == 0x7f:
				buf = append(buf, '\\', 'u', '0', '0', hex[c>>4], hex[c&0xf])
			default:
				buf = append(buf, c)
			}
			i++
			continue
		}
		r, size := utf8.DecodeRuneInString(s[i:])
		switch {
		case r == utf8.RuneError && size == 1:
			buf = append(buf, "\\ufffd"...)
		case r == '\u2028':
			buf = append(buf, "\\u2028"...)
		case r == '\u2029':
			buf = append(buf, "\\u2029"...)
		default:
			buf = append(buf, s[i:i+size]...)
		}
		i += size
	}
	return append(buf, '"')
}

// Str returns a JSON string value.
func Str(s string) *Value { return &Value{Kind: String, Str: s} }

// Obj returns an empty JSON object.
func Obj() *Value { return &Value{Kind: Object, Obj: map[string]*Value{}} }

// Set sets a member of an object, keeping the position of an existing key.
func (v *Value) Set(key string, val *Value) {
	if _, ok := v.Obj[key]; !ok {
		v.Keys = append(v.Keys, key)
	}
	v.Obj[key] = val
}

// MarshalJSON lets encoding/json embed a Value.
func (v *Value) MarshalJSON() ([]byte, error) { return v.Marshal(), nil }
