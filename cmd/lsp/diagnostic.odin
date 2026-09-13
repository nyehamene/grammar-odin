package lsp

import "core:encoding/json"

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

// release_diagnostics clears the diagnostics for uri on the client.
release_diagnostics :: proc(srv: ^Server, uri: string) {
	diags := make([]Diagnostic, 0)
	defer delete(diags)
	publish_diagnostics(srv, uri, diags)
}

// handle_text_document_diagnostic implements the pull-based
// textDocument/diagnostic request (LSP 3.17).
handle_text_document_diagnostic :: proc(srv: ^Server, id: Request_Id, obj: json.Object) -> (ok: bool) {
	params := json_object(obj, "params") or_return
	text_doc := json_object(params, "textDocument") or_return
	uri := json_string(text_doc, "uri") or_return

	diags := diagnostics_for(srv, uri)
	defer delete(diags)

	result := Pull_Diagnostic_Result{
		kind  = "full",
		items = diags,
	}
	buf, err := json.marshal(result, allocator = context.temp_allocator)
	if err != nil {
		debugf(srv, "failed to marshal diagnostic result: %v", err)
		return false
	}

	frame := write_response(srv.stdout, id, string(buf))
	debug(srv, frame)
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

	cu := check.new_compilation_unit()
	defer check.destroy_compilation_unit(&cu)

	for _, d in srv.documents {
		abs := uri_to_path(d.uri) or_continue
		display := check.display_of(&cu, abs)
		check.load_source(&cu, abs, display, d.text)
	}
	check.run_checks(&cu)

	target_abs, abs_ok := uri_to_path(doc.uri)
	if !abs_ok {
		return make([]Diagnostic, 0)
	}
	defer delete(target_abs)

	target_display := check.display_of(&cu, target_abs)
	defer delete(target_display)

	count := 0
	for e in cu.errors {
		if e.path == target_display {
			count += 1
		}
	}

	diags := make([]Diagnostic, count)
	index := 0
	for e in cu.errors {
		if e.path != target_display {
			continue
		}
		start := Position{line = e.line - 1, character = e.col - 1}
		end := start
		if extent := word_extent(doc.text, e.offset); extent > 0 {
			end = position_at_offset(doc.text, e.offset + extent)
		}
		diags[index] = Diagnostic{
			range    = Range{start = start, end = end},
			severity = 1, // Error
			source   = "grammar",
			message  = clone_string(&srv.arena, e.message),
		}
		index += 1
	}

	return diags
}

// publish_diagnostics sends the textDocument/publishDiagnostics notification.
publish_diagnostics :: proc(srv: ^Server, uri: string, diagnostics: []Diagnostic) {
	params := Publish_Diagnostics_Params{
		uri         = uri,
		diagnostics = diagnostics,
	}

	buf, err := json.marshal(params, allocator = context.temp_allocator)
	if err != nil {
		debugf(srv, "failed to marshal publishDiagnostics: %v", err)
		return
	}

	frame := write_notification(srv.stdout, "textDocument/publishDiagnostics", string(buf))
	debug(srv, frame)
}