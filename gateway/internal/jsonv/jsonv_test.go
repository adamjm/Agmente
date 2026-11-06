package jsonv

import (
	"strings"
	"testing"
)

func TestRoundTripMatchesJSONParseThenStringify(t *testing.T) {
	cases := map[string]string{
		`{"b":1,"a":2,"b":3}`:                `{"b":3,"a":2}`, // first position, last value
		`{ "x" : [ 1 , 2.50 , -0 , 1e3 ] }`:  `{"x":[1,2.50,-0,1e3]}`,
		`{"id":9007199254740993}`:            `{"id":9007199254740993}`, // not rounded
		`{"s":"a\u2028b\u2029c"}`:            `{"s":"a\u2028b\u2029c"}`,
		"{\"s\":\"a\u2028b\"}":               `{"s":"a\u2028b"}`, // raw U+2028 is escaped
		`{"s":"q\"\\\/\b\f\n\r\t\u0001"}`:    `{"s":"q\"\\/\b\f\n\r\t\u0001"}`,
		`{"e":{},"a":[],"n":null,"t":true}`: `{"e":{},"a":[],"n":null,"t":true}`,
		`"just a string"`:                    `"just a string"`,
	}
	for in, want := range cases {
		v, err := Parse([]byte(in))
		if err != nil {
			t.Fatalf("%s: %v", in, err)
		}
		if got := string(v.Marshal()); got != want {
			t.Errorf("%s: got %s want %s", in, got, want)
		}
		if strings.ContainsAny(string(v.Marshal()), "\n\r\u2028\u2029") {
			t.Errorf("%s: output has a line break", in)
		}
	}
}

func TestParseRejectsTrailingDataAndInvalidJSON(t *testing.T) {
	for _, in := range []string{``, `{} {}`, `{"a":1}x`, `{"a":01}`, `{'a':1}`, `[1,]`, `{"a":1,}`, `nul`} {
		if _, err := Parse([]byte(in)); err == nil {
			t.Errorf("%q: expected an error", in)
		}
	}
}

func TestGetIsExact(t *testing.T) {
	v, _ := Parse([]byte(`{"METHOD":"x","Cwd":"/etc"}`))
	if v.Get("method") != nil || v.Get("cwd") != nil {
		t.Fatal("lookup must be case-sensitive")
	}
}

func TestInt(t *testing.T) {
	for in, want := range map[string]bool{`8787`: true, `8787.0`: true, `1.5`: false, `1e400`: false, `"1"`: false, `-1`: true} {
		v, _ := Parse([]byte(in))
		if _, ok := v.Int(); ok != want {
			t.Errorf("%s: Int ok = %v, want %v", in, ok, want)
		}
	}
}
