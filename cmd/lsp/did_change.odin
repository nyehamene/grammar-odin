package lsp

import "core:encoding/json"

// handle_did_change implements textDocument/didChange for full document sync:
// the last content change carries the entire new document text.
handle_did_change :: proc(srv: ^Server, obj: json.Object) -> (ok: bool) {
	params := json_object(obj, "params") or_return
	text_doc := json_object(params, "textDocument") or_return

	uri := json_string(text_doc, "uri") or_return
	version := json_int(text_doc, "version") or_return

	doc, found := srv.documents[uri]
	if !found {
		return true
	}

	changes, has_changes := params["contentChanges"].(json.Array)
	if !has_changes || len(changes) == 0 {
		return true
	}

	last, last_ok := changes[len(changes) - 1].(json.Object)
	if !last_ok {
		return true
	}
	text := json_string(last, "text") or_return

	doc.text = clone_string(&srv.arena, text)
	doc.version = int(version)

	public_diagnostics(srv, doc.uri)
	return true
}
