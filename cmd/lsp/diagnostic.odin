package lsp

import "core:encoding/json"
import "core:strings"

import "../check"

Session :: struct {}

// Diagnostic is an LSP diagnostic for a range in a document.
Diagnostic :: struct {
	range:    Range,
	severity: int,
	source:   string,
	message:  string,
}

// Publish_Diagnostics_Params is the payload of textDocument/publishDiagnostics.
Publish_Diagnostics_Params :: struct {
	uri:         string,
	diagnostics: []Diagnostic,
}

// Pull_Diagnostic_Result is the result of a textDocument/diagnostic request.
Pull_Diagnostic_Result :: struct {
	kind:  string,
	items: []Diagnostic,
}

// public_diagnostics computes the diagnostics for uri and pushes them to the
// client with textDocument/publishDiagnostics.
public_diagnostics :: proc(srv: ^Server, uri: string) {
	diags := diagnostics_for(srv, uri)
	defer delete(diags)
	publish_diagnostics(srv, uri, diags)
}

// publish_namespace_diagnostics computes diagnostics for every grammar file in
// the namespace tree rooted at abs_dir and pushes them to the client, one
// textDocument/publishDiagnostics notification per file. Files that check
// clean are published with an empty diagnostic list so stale errors are
// cleared.
publish_namespace_diagnostics :: proc(srv: ^Server, abs_dir: string) {
	cu := index_namespace(srv, abs_dir)
	defer check.destroy_compilation_unit(&cu)

	for abs, fi in cu.files {
		if !is_under_namespace(abs_dir, fi.namespace_path) do continue
		uri := path_to_uri(abs)
		diags := file_diagnostics(srv, &cu, fi.display, fi.src)
		publish_diagnostics(srv, uri, diags)
		delete(uri)
		delete(diags)
	}
}

// is_under_namespace reports whether the namespace tree rooted at ns_dir
// contains dir (dir itself, or a descendant directory).
is_under_namespace :: proc(ns_dir, dir: string) -> bool {
	if len(dir) < len(ns_dir) do return false
	if !strings.has_prefix(dir, ns_dir) do return false
	return len(dir) == len(ns_dir) || dir[len(ns_dir)] == '/'
}

// release_diagnostics clears the diagnostics for uri on the client.
release_diagnostics :: proc(srv: ^Server, uri: string) {
	diags := make([]Diagnostic, 0)
	defer delete(diags)
	publish_diagnostics(srv, uri, diags)
}

// handle_text_document_diagnostic implements the pull-based
// textDocument/diagnostic request (LSP 3.17).
handle_text_document_diagnostic :: proc(
	srv: ^Server,
	id: Request_Id,
	obj: json.Object,
) -> (
	ok: bool,
) {
	params := json_object(obj, "params") or_return
	text_doc := json_object(params, "textDocument") or_return
	uri := json_string(text_doc, "uri") or_return

	diags := diagnostics_for(srv, uri)
	defer delete(diags)

	result := Pull_Diagnostic_Result {
		kind  = "full",
		items = diags,
	}
	buf, err := json.marshal(result, allocator = context.temp_allocator)
	if err != nil {
		debugf(srv, "failed to marshal diagnostic result: %v", err)
		return false
	}

	write_response(srv, id, string(buf))
	return true
}

// diagnostics_for builds a compilation unit from all open documents and returns
// the diagnostics that belong to uri. The returned slice is owned by the
// caller.
diagnostics_for :: proc(srv: ^Server, uri: string) -> []Diagnostic {
	doc, found := srv.documents[uri]
	if !found {
		return make([]Diagnostic, 0)
	}

	cu := index_documents(srv)
	defer check.destroy_compilation_unit(&cu)

	target_abs, abs_ok := uri_to_path(doc.uri)
	if !abs_ok {
		return make([]Diagnostic, 0)
	}
	defer delete(target_abs)

	target_display := check.display_of(&cu, target_abs)
	defer delete(target_display)

	return file_diagnostics(srv, &cu, target_display, doc.text)
}

// file_diagnostics collects the diagnostics belonging to the loaded file with
// the given display path, using src to compute ranges. The returned slice is
// owned by the caller; each Diagnostic.message is cloned into the server
// arena.
file_diagnostics :: proc(
	srv: ^Server,
	cu: ^check.Compilation_Unit,
	display, src: string,
) -> []Diagnostic {
	count := 0
	for e in cu.errors {
		if e.path == display {
			count += 1
		}
	}

	diags := make([]Diagnostic, count)
	index := 0
	for e in cu.errors {
		if e.path != display {
			continue
		}
		start := Position {
			line      = e.line - 1,
			character = e.col - 1,
		}
		end := start
		if extent := word_extent(src, e.offset); extent > 0 {
			end = position_at_offset(src, e.offset + extent)
		}
		diags[index] = Diagnostic {
			range    = Range{start = start, end = end},
			severity = severity_code(e.severity),
			source   = "grammar",
			message  = clone_string(&srv.arena, e.message),
		}
		index += 1
	}

	return diags
}

// severity_code maps a checker severity to the LSP DiagnosticSeverity value the
// protocol defines: 1 = Error, 2 = Warning.
severity_code :: proc(severity: check.Severity) -> int {
	return 2 if severity == .Warning else 1
}

// publish_diagnostics sends the textDocument/publishDiagnostics notification.
publish_diagnostics :: proc(srv: ^Server, uri: string, diagnostics: []Diagnostic) {
	params := Publish_Diagnostics_Params {
		uri         = uri,
		diagnostics = diagnostics,
	}

	buf, err := json.marshal(params, allocator = context.temp_allocator)
	if err != nil {
		debugf(srv, "failed to marshal publishDiagnostics: %v", err)
		return
	}

	write_notification(srv, "textDocument/publishDiagnostics", string(buf))
}
