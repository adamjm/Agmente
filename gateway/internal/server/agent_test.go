package server

import (
	"io"
	"strings"
	"testing"
)

// chunkReader returns its parts one Read at a time, like a pipe that delivers partial writes.
type chunkReader struct{ parts []string }

func (c *chunkReader) Read(p []byte) (int, error) {
	if len(c.parts) == 0 {
		return 0, io.EOF
	}
	n := copy(p, c.parts[0])
	c.parts[0] = c.parts[0][n:]
	if c.parts[0] == "" {
		c.parts = c.parts[1:]
	}
	return n, nil
}

func collect(r io.Reader, max int64) (lines []string, overflows int) {
	readLines(r, max, func(l []byte) { lines = append(lines, string(l)) }, func() { overflows++ })
	return
}

func TestReadLinesJoinsChunksAndHandlesCRLF(t *testing.T) {
	lines, overflows := collect(&chunkReader{[]string{"ab", "c\r\nde\n\nf"}}, 10)
	if strings.Join(lines, "|") != "abc|de" || overflows != 0 {
		t.Fatalf("got %q, %d overflows", lines, overflows)
	}
}

func TestReadLinesLimitIsExact(t *testing.T) {
	line := strings.Repeat("x", 10)
	if lines, n := collect(strings.NewReader(line+"\n"), 10); len(lines) != 1 || n != 0 {
		t.Fatalf("a line of exactly max bytes must pass: %q %d", lines, n)
	}
	if lines, n := collect(strings.NewReader(line+"\r\n"), 10); n != 1 || len(lines) != 0 {
		t.Fatalf("max+1 bytes (with CR) must overflow, as in the Node gateway: %q %d", lines, n)
	}
	if lines, n := collect(strings.NewReader(line+"x\nok\n"), 10); n != 1 || len(lines) != 0 {
		t.Fatalf("an overflow stops the stream: %q %d", lines, n)
	}
}

func TestReadLinesOverflowsBeyondTheBufferSize(t *testing.T) {
	big := strings.Repeat("y", 200*1024)
	if lines, n := collect(strings.NewReader(big+"\n"), 150*1024); n != 1 || len(lines) != 0 {
		t.Fatalf("got %d lines, %d overflows", len(lines), n)
	}
	if lines, n := collect(strings.NewReader(big+"\n"), 300*1024); n != 0 || len(lines) != 1 || len(lines[0]) != len(big) {
		t.Fatalf("a long line under the cap must pass whole: %d lines, %d overflows", len(lines), n)
	}
}
