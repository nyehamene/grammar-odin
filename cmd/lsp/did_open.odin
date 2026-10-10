package lsp

import "core:encoding/json"
import "core:mem/virtual"

handle_did_open :: proc(srv: ^Server, obj: json.Object) -> (ok: bool) {
	params := json_object(obj, "params") or_return
	text_doc := json_object(params, "textDocument") or_return

	uri := json_string(text_doc, "uri") or_return
	text := json_string(text_doc, "text") or_return
	version := json_int(text_doc, "version") or_return
	lang_id := json_string(text_doc, "languageId") or_return

	if prev, exists := srv.documents[uri]; exists {
		prev.version = int(version)
		prev.lang_id = clone_string(&srv.arena, lang_id)
		prev.text = clone_string(&srv.arena, text)
	} else {
		alloc := virtual.arena_allocator(&srv.arena)
		doc := new(Document, alloc)
		doc.uri = clone_string(&srv.arena, uri)
		doc.lang_id = clone_string(&srv.arena, lang_id)
		doc.version = int(version)
		doc.text = clone_string(&srv.arena, text)
		srv.documents[doc.uri] = doc
	}

	// Publish diagnostics for the whole namespace the file lives in: every
	// grammar file in its directory tree is loaded (reading from disk those
	// that are not open) and each one's diagnostics are pushed to the client.
	publish_diagnostics_for_document(srv, uri)
	return true
}