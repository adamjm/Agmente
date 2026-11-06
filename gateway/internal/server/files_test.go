package server

import (
	"strings"
	"testing"
)

var testKey = []byte("0123456789abcdef0123456789abcdef")

func TestFileTokenRoundTrip(t *testing.T) {
	in := fileClaims{P: "abc123def456", R: "docs/readme.md", E: 2000000000}
	tok := signFileToken(testKey, in)
	got, ok := verifyFileToken(testKey, tok)
	if !ok || got != in {
		t.Fatalf("round trip: ok=%v got=%+v", ok, got)
	}
}

func TestFileTokenRejectsTampering(t *testing.T) {
	tok := signFileToken(testKey, fileClaims{P: "p", R: "a.txt", E: 2000000000})
	other := signFileToken(testKey, fileClaims{P: "p", R: "b.txt", E: 2000000000})
	dot := strings.IndexByte(tok, '.')
	odot := strings.IndexByte(other, '.')
	cases := map[string]string{
		"payload changed":     other[:odot] + tok[dot:],    // another path's payload, this signature
		"signature changed":   tok[:dot+1] + other[dot+1:], // another signature
		"signature truncated": tok[:len(tok)-2],
		"no dot":              strings.Replace(tok, ".", "", 1),
		"two dots":            tok + ".x",
		"not base64":          "!!." + tok[dot+1:],
		"empty":               "",
		"oversize":            strings.Repeat("a", fileTokenMaxLen+1),
	}
	for name, bad := range cases {
		if _, ok := verifyFileToken(testKey, bad); ok {
			t.Errorf("%s: accepted", name)
		}
	}
	if _, ok := verifyFileToken([]byte("another-key-another-key-another!"), tok); ok {
		t.Error("token from another key accepted")
	}
}

func TestFileTokenRejectsMissingFields(t *testing.T) {
	// A correctly signed payload with no project or no path is still refused.
	for _, c := range []fileClaims{{P: "", R: "a.txt", E: 1}, {P: "p", R: "", E: 1}} {
		if _, ok := verifyFileToken(testKey, signFileToken(testKey, c)); ok {
			t.Errorf("claims %+v accepted", c)
		}
	}
}

func TestValidRelPath(t *testing.T) {
	good := []string{"a.txt", "dir/a.txt", "dir/.hidden", "naïve/café.md", "a..b", "...x"}
	bad := []string{
		"", "/etc/passwd", "../x", "a/../b", "a/..", "./a", "a/./b", "a//b", "a/", "a\\b",
		"a\x00b", "a\nb", "a\x7fb", "\u0085x", strings.Repeat("a", fileMaxPathLen+1),
	}
	for _, p := range good {
		if !validRelPath(p) {
			t.Errorf("%q refused", p)
		}
	}
	for _, p := range bad {
		if validRelPath(p) {
			t.Errorf("%q accepted", p)
		}
	}
}

func TestFileTypesAreAllowListed(t *testing.T) {
	if servedTypes[".svg"] != "text/plain; charset=utf-8" {
		t.Errorf("svg must be served as text, got %q", servedTypes[".svg"])
	}
	for _, ext := range []string{".exe", ".sh", ".php", ".pdf", ""} {
		if _, ok := servedTypes[ext]; ok {
			t.Errorf("%q must not be served", ext)
		}
	}
}
