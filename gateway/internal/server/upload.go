package server

// Phone file upload into a project folder (D-115). The owner's phone sends one file in one JSON-RPC
// message; the gateway writes it into the project root, never into a subfolder, and never over an
// existing name. The agent (Bob or oh-my-pi) reads it through the project's bind mount (D-085).
//
// Methods, both answered by the gateway itself (D-024), both starting no agent:
//   _acpcode/files/upload {projectId, path, contentBase64}  -> {path, bytes}
//   _acpcode/files/stat   {projectId, path}                 -> {exists, size?, sha256?}

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"io"
	"io/fs"
	"os"
	"strings"
	"sync"
	"syscall"

	"acpcode/gateway/internal/audit"
	"acpcode/gateway/internal/jsonv"
	"acpcode/gateway/internal/store"
)

const (
	// maxUploadBytes is the decoded size cap of one upload (the critic's verdict, D-115). It is a
	// constant, not config: the phone checks the same number before it sends.
	maxUploadBytes = 8 << 20
	// maxUploadEncoded is the base64 length of maxUploadBytes: 4 * ceil(n / 3). A longer string is
	// refused before it is decoded.
	maxUploadEncoded = 4 * ((maxUploadBytes + 2) / 3)
	maxUploadName    = 64 // the folder-name rule (D-091)
)

// uploadTypes is the allow-list of file extensions (lowercase, without the dot). Scripts, markup that
// a browser runs, and binaries are not in it. PDF is stored and not previewed (D-062 serves neither).
var uploadTypes = map[string]bool{
	"png": true, "jpg": true, "jpeg": true, "gif": true, "webp": true, "heic": true,
	"pdf": true, "txt": true, "md": true, "csv": true, "json": true,
}

// uploadReserved are names Bob or oh-my-pi reads as instructions or agent configuration (D-108). An
// upload may not take them, whatever their case.
var uploadReserved = map[string]bool{"agents.md": true, "claude.md": true, "opencode.json": true}

// uploadLocks holds the projects with an upload in flight. The zero value is ready to use.
type uploadLocks struct {
	mu   sync.Mutex
	busy map[string]bool
}

func (u *uploadLocks) take(projectID string) bool {
	u.mu.Lock()
	defer u.mu.Unlock()
	if u.busy == nil {
		u.busy = map[string]bool{}
	}
	if u.busy[projectID] {
		return false
	}
	u.busy[projectID] = true
	return true
}

func (u *uploadLocks) release(projectID string) {
	u.mu.Lock()
	defer u.mu.Unlock()
	delete(u.busy, projectID)
}

// Refusal reasons for the audit line (fixed set, D-115). The text sent to the phone is fixed too.
const (
	uploadRefusedName     = "name"
	uploadRefusedType     = "type"
	uploadRefusedReserved = "reserved"
	uploadRefusedSecret   = "secret"
	uploadRefusedExists   = "exists"
	uploadRefusedSize     = "too_large"
	uploadRefusedBase64   = "bad_base64"
	uploadRefusedMissing  = "missing_folder"
	uploadRefusedOutside  = "outside_root"
	uploadRefusedBusy     = "busy"
)

// uploadNameReason checks the name of an upload. It returns "" when the name may be uploaded, else
// one of the refusal reasons above. The name is one path component; the rules are the folder-name
// rules (D-091, ASCII, no leading dot, no leading or trailing space, at most 64 bytes), an allowed
// extension, not a reserved name, and not a secret by the built-in or the project's deny-list.
func uploadNameReason(name string, denyExtra []string) string {
	switch {
	case name == "" || len(name) > maxUploadName || name[0] == '.' || name[0] == ' ' || name[len(name)-1] == ' ':
		return uploadRefusedName
	}
	for i := 0; i < len(name); i++ {
		if !folderNameByte(name[i]) {
			return uploadRefusedName
		}
	}
	dot := strings.LastIndexByte(name, '.')
	if dot <= 0 || !uploadTypes[strings.ToLower(name[dot+1:])] {
		return uploadRefusedType
	}
	if uploadReserved[strings.ToLower(name)] {
		return uploadRefusedReserved
	}
	if isSecretFor(denyExtra, name) {
		return uploadRefusedSecret
	}
	return ""
}

// uploadSyntaxReason is the part of the name rule that stat needs: one component, the folder-name
// bytes. Stat reports whether a name exists for any name of this shape; it hashes only names that
// pass uploadNameReason (D-115, the read-oracle rule).
func uploadSyntaxReason(name string) string {
	if name == "" || len(name) > maxUploadName || name[0] == '.' {
		return uploadRefusedName
	}
	for i := 0; i < len(name); i++ {
		if !folderNameByte(name[i]) {
			return uploadRefusedName
		}
	}
	return ""
}

var uploadRefusalText = map[string]string{
	uploadRefusedName:     "the name must be a file name of 1 to 64 characters: letters, digits, space, dot, hyphen and underscore, not starting with a dot",
	uploadRefusedType:     "this file type is not allowed. Allowed: png, jpg, jpeg, gif, webp, heic, pdf, txt, md, csv, json",
	uploadRefusedReserved: "this name is reserved: agent instruction files cannot be uploaded",
	uploadRefusedSecret:   "this looks like a secret file and cannot be uploaded",
	uploadRefusedExists:   "a file with this name already exists in the project; nothing was changed",
	uploadRefusedSize:     "the file is larger than 8 MB",
	uploadRefusedBase64:   "the file content is not valid base64",
	uploadRefusedMissing:  "the project folder is missing",
	uploadRefusedOutside:  "the project folder is outside the allowed roots",
	uploadRefusedBusy:     "an upload to this project is already in progress",
}

func uploadRefusal(reason string) *rpcError {
	code := rpcInvalidParams
	if reason == uploadRefusedBusy {
		code = -32000 // a retry later, not a bad request (the agent-capacity code, D-025)
	}
	return &rpcError{Code: code, Message: uploadRefusalText[reason]}
}

// serveUploads answers the two upload methods. handled is false for any other method.
func (s *Server) serveUploads(ctx context.Context, who audit.Who, method string, params *jsonv.Value) (result any, rerr *rpcError, handled bool) {
	switch method {
	case "_acpcode/files/upload":
		result, rerr = s.uploadFile(ctx, who, params)
		return result, rerr, true
	case "_acpcode/files/stat":
		result, rerr = s.statUpload(ctx, params)
		return result, rerr, true
	}
	return nil, nil, false
}

// uploadProject reads the project a request names. A missing project is refused the same way the
// skills methods refuse one.
func (s *Server) uploadProject(ctx context.Context, params *jsonv.Value) (*store.Project, string, *rpcError) {
	pid, ok := params.Get("projectId").StringValue()
	if !ok || pid == "" {
		return nil, "", invalidParams("projectId is required")
	}
	name, ok := params.Get("path").StringValue()
	if !ok {
		return nil, "", invalidParams("path is required and must be a file name")
	}
	p, err := s.store.ProjectByID(ctx, pid)
	if err != nil {
		return nil, "", &rpcError{Code: rpcInternal, Message: "cannot read projects"}
	}
	if p == nil {
		return nil, "", invalidParams("unknown project")
	}
	return p, name, nil
}

// openUploadRoot opens the project folder for the upload. The folder must still exist, be inside a
// configured root, and be reached through its realpath; os.Root confines every later step to it.
func (s *Server) openUploadRoot(p *store.Project) (*os.Root, *rpcError, string) {
	real, err := realpath(p.Path)
	if err != nil {
		return nil, uploadRefusal(uploadRefusedMissing), uploadRefusedMissing
	}
	if !isInsideRoots(real, s.roots) {
		return nil, uploadRefusal(uploadRefusedOutside), uploadRefusedOutside
	}
	root, err := os.OpenRoot(real)
	if err != nil {
		return nil, uploadRefusal(uploadRefusedMissing), uploadRefusedMissing
	}
	return root, nil, ""
}

func (s *Server) uploadFile(ctx context.Context, who audit.Who, params *jsonv.Value) (any, *rpcError) {
	p, name, rerr := s.uploadProject(ctx, params)
	if rerr != nil {
		return nil, rerr
	}
	refuse := func(reason string, valid bool) (any, *rpcError) {
		f := with(who, audit.Fields{Project: p.ID, Reason: reason})
		if valid {
			f.Path = name
		}
		s.audit.Log("file_upload_refused", f)
		return nil, uploadRefusal(reason)
	}
	if reason := uploadNameReason(name, p.DenyPaths); reason != "" {
		return refuse(reason, false)
	}
	content, ok := params.Get("contentBase64").StringValue()
	if !ok {
		return nil, invalidParams("contentBase64 is required and must be a string")
	}
	if len(content) > maxUploadEncoded {
		return refuse(uploadRefusedSize, true)
	}
	if strings.ContainsAny(content, " \t\r\n") {
		return refuse(uploadRefusedBase64, true)
	}
	data, err := base64.StdEncoding.Strict().DecodeString(content)
	if err != nil {
		return refuse(uploadRefusedBase64, true)
	}
	if len(data) > maxUploadBytes {
		return refuse(uploadRefusedSize, true)
	}
	// One upload per project at a time bounds the memory held at once (D-115).
	if !s.uploads.take(p.ID) {
		return refuse(uploadRefusedBusy, true)
	}
	defer s.uploads.release(p.ID)

	root, rerr, reason := s.openUploadRoot(p)
	if rerr != nil {
		return refuse(reason, true)
	}
	defer root.Close()
	if _, err := root.Lstat(name); err == nil {
		return refuse(uploadRefusedExists, true)
	} else if !errors.Is(err, fs.ErrNotExist) {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot write the file"}
	}
	if err := writeUploadNoClobber(root, name, data); err != nil {
		if errors.Is(err, fs.ErrExist) {
			return refuse(uploadRefusedExists, true)
		}
		s.audit.Log("file_upload_refused", with(who, audit.Fields{Project: p.ID, Path: name, Reason: "write"}))
		return nil, &rpcError{Code: rpcInternal, Message: "cannot write the file"}
	}
	f := with(who, audit.Fields{Project: p.ID, Path: name, HasBytes: true, Bytes: int64(len(data))})
	s.audit.Log("file_uploaded", f)
	return map[string]any{"path": name, "bytes": len(data)}, nil
}

// writeUploadNoClobber writes data as <root>/<name> at mode 0644 without replacing anything. The bytes go
// to a temporary name created with O_EXCL, are flushed, and are then hard-linked to the final name:
// Link fails with EEXIST when the name appeared meanwhile, so nothing is overwritten. The temporary
// name is removed in every case, and the folder is flushed after the link.
func writeUploadNoClobber(root *os.Root, name string, data []byte) (err error) {
	suffix, err := randomHex(8)
	if err != nil {
		return err
	}
	tmp := "." + name + "." + suffix + ".upload"
	f, err := root.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o644)
	if err != nil {
		return err
	}
	defer func() {
		_ = root.Remove(tmp)
	}()
	if err = f.Chmod(0o644); err != nil {
		_ = f.Close()
		return err
	}
	if _, err = f.Write(data); err != nil {
		_ = f.Close()
		return err
	}
	if err = f.Sync(); err != nil {
		_ = f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	if err = root.Link(tmp, name); err != nil {
		return err
	}
	if d, derr := root.Open("."); derr == nil {
		_ = d.Sync()
		_ = d.Close()
	}
	return nil
}

// statUpload reports whether a file exists under the name. For a name the upload would accept, and that is
// a regular file, it also returns the size and, up to the upload cap, the SHA-256. It never returns content.
func (s *Server) statUpload(ctx context.Context, params *jsonv.Value) (any, *rpcError) {
	p, name, rerr := s.uploadProject(ctx, params)
	if rerr != nil {
		return nil, rerr
	}
	if reason := uploadSyntaxReason(name); reason != "" {
		return nil, uploadRefusal(reason)
	}
	root, rerr, _ := s.openUploadRoot(p)
	if rerr != nil {
		return nil, rerr
	}
	defer root.Close()
	info, err := root.Lstat(name)
	if errors.Is(err, fs.ErrNotExist) {
		return map[string]any{"exists": false}, nil
	}
	if err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot read the file"}
	}
	out := map[string]any{"exists": true}
	if !info.Mode().IsRegular() || uploadNameReason(name, p.DenyPaths) != "" {
		return out, nil // a link, a folder, or a name the upload would refuse: exists only
	}
	out["size"] = info.Size()
	if info.Size() > maxUploadBytes {
		return out, nil
	}
	f, err := root.Open(name)
	if err != nil {
		return out, nil
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, io.LimitReader(f, maxUploadBytes+1)); err != nil {
		return nil, &rpcError{Code: rpcInternal, Message: "cannot read the file"}
	}
	out["sha256"] = hex.EncodeToString(h.Sum(nil))
	return out, nil
}
