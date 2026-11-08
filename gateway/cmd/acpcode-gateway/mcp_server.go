package main

// `acpcode-gateway --config <file> mcp-server list|put|delete [id]` (D-107): the Mac admin's way to
// keep the gateway's own MCP server list. `put` reads one JSON entry on stdin. Its secret values
// (header values, stdio arguments and environment values) go to the 0600 secrets file and are never
// printed. Nothing here starts a process, and the gateway reads the files again on each use, so a
// change needs no restart.

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/config"
	"acpcode/gateway/internal/mcpservers"
)

const mcpServerUsage = "Usage: acpcode-gateway mcp-server --config <file> list\n" +
	"       acpcode-gateway mcp-server --config <file> put < entry.json\n" +
	"       acpcode-gateway mcp-server --config <file> delete <id>\n"

// maxEntryBytes bounds the JSON entry read on stdin, above the largest entry the list accepts.
const maxEntryBytes = 300 * 1024

func mcpServerCommand(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("mcp-server", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	configPath := fs.String("config", "", "config file")
	if err := fs.Parse(args); err != nil || *configPath == "" || fs.NArg() == 0 {
		fmt.Fprint(stderr, mcpServerUsage)
		return 2
	}
	rest := fs.Args()
	cfg, err := config.Load(*configPath)
	if err != nil {
		fmt.Fprintln(stderr, err.Error())
		return 1
	}
	lib := mcpservers.Open(cfg.StateDir)
	logger := audit.New(stderr)
	switch {
	case rest[0] == "list" && len(rest) == 1:
		list, err := lib.List()
		if err != nil {
			fmt.Fprintln(stderr, err.Error())
			return 1
		}
		return printJSON(stdout, stderr, map[string]any{"servers": list})
	case rest[0] == "put" && len(rest) == 1:
		var in mcpservers.Input
		dec := json.NewDecoder(io.LimitReader(stdin, maxEntryBytes))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&in); err != nil {
			fmt.Fprintln(stderr, "the entry on stdin is not valid JSON, or has a field the list does not have")
			return 1
		}
		entry, err := lib.Put(in)
		if err != nil {
			fmt.Fprintln(stderr, err.Error())
			return 1
		}
		logger.Log("mcp_server_put", audit.Fields{Reason: "id=" + entry.ID})
		return printJSON(stdout, stderr, mcpservers.Redact(entry))
	case rest[0] == "delete" && len(rest) == 2:
		id := rest[1]
		if !mcpservers.ValidID(id) {
			fmt.Fprint(stderr, mcpServerUsage)
			return 2
		}
		found, err := lib.Delete(id)
		if err != nil {
			fmt.Fprintln(stderr, err.Error())
			return 1
		}
		if !found {
			fmt.Fprintln(stderr, mcpservers.ErrNotFound.Error())
			return 1
		}
		logger.Log("mcp_server_deleted", audit.Fields{Reason: "id=" + id})
		return printJSON(stdout, stderr, map[string]string{"deleted": id})
	}
	fmt.Fprint(stderr, mcpServerUsage)
	return 2
}

func printJSON(stdout, stderr io.Writer, v any) int {
	out, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		fmt.Fprintln(stderr, "cannot print the result")
		return 1
	}
	fmt.Fprintln(stdout, string(out))
	return 0
}
