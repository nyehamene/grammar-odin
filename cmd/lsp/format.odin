package lsp

import "core:encoding/json"

import fmtcmd "../fmt"

// handle_format_document implements textDocument/formatting. It returns a
// single edit replacing the whole document with its formatted text, or [] when
// the document is already formatted, or null when it cannot be formatted (for
// example because it does not parse).
handle_format_document :: proc(srv: ^Server, id: Request_Id, obj: json.Object) -> (ok: bool) {
	params := json_object(obj, "params") or_return
	text_doc := json_object(params, "textDocument") or_return
	uri := json_string(text_doc, "uri") or_return

	doc, found := srv.documents[uri]
	if !found {
		write_response(srv, id, "[]")
		return true
	}

	text, format_ok := fmtcmd.Format_Text(doc.text, "<uri>", srv.logout)
	defer delete(text)
	if !format_ok {
		write_response(srv, id, "null")
		return true
	}

	if text == doc.text {
		write_response(srv, id, "[]")
		return true
	}

	edit := Text_Edit {
		range = Range {
			start = Position{line = 0, character = 0},
			end = position_at_offset(doc.text, len(doc.text)),
		},
		new_text = text,
	}

	edits := []Text_Edit{edit}
	buf, err := json.marshal(edits, allocator = context.temp_allocator)
	if err != nil {
		debugf(srv, "failed to marshal formatting edits: %v", err)
		return false
	}

	debugf(srv, "formatting document %s", uri)
	write_response(srv, id, string(buf))
	return true
}