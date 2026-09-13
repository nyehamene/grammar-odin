package lsp

import "core:encoding/json"

// handle_did_close implements textDocument/didClose. The document is removed
// from the open set and its diagnostics are cleared.
handle_did_close :: proc(srv: ^Server, obj: json.Object) -> (ok: bool) {
	params := json_object(obj, "params") or_return
	text_doc := json_object(params, "textDocument") or_return

	uri := json_string(text_doc, "uri") or_return

	delete_key(&srv.documents, uri)

	release_diagnostics(srv, uri)
	return true
}