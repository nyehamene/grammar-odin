package lsp

import "core:encoding/json"

handle_did_open :: proc(srv: ^Server, obj: json.Object) -> (ok: bool) {
	params := json_object(obj, "params") or_return
	text_doc := json_object(params, "textDocument") or_return

	uri := json_string(text_doc, "uri") or_return
	text := json_string(text_doc, "text") or_return
	version := json_int(text_doc, "version") or_return
	lang_id := json_string(text_doc, "languageId") or_return

	if prev, ok := srv.documents[uri]; ok {
		prev.version = int(version)
		prev.lang_id = lang_id
		prev.text = text
	}

	public_diagnostics(srv, uri)
	return true
}
