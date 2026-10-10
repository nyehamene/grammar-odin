package lsp

import "core:encoding/json"
import "core:os"

// handle_did_close implements textDocument/didClose. The document is removed
// from the open set and the namespace it lives in is re-published, so every
// file's diagnostics reflect the saved-on-disk state once the closed file's
// in-memory edits stop taking part.
handle_did_close :: proc(srv: ^Server, obj: json.Object) -> (ok: bool) {
	params := json_object(obj, "params") or_return
	text_doc := json_object(params, "textDocument") or_return

	uri := json_string(text_doc, "uri") or_return

	delete_key(&srv.documents, uri)

	// Re-publish the namespace: the closed file, when it is still on disk,
	// takes part with its saved text, and for a scratch document this
	// publishes an empty list, clearing its diagnostics.
	abs, abs_ok := uri_to_path(uri)
	if abs_ok {
		defer delete(abs)
	}
	publish_diagnostics_for_document(srv, uri)

	// A file that is not on disk cannot appear in the namespace load, so its
	// diagnostics are dropped by hand.
	if !abs_ok || !os.is_file(abs) {
		release_diagnostics(srv, uri)
	}
	return true
}