package lsp

import "core:encoding/json"

import "../check"

// Document_Highlight_Kind mirrors the LSP DocumentHighlightKind enum values.
Document_Highlight_Kind :: enum {
	Text  = 1,
	Read  = 2,
	Write = 3,
}

Document_Highlight :: struct {
	range: Range,
	kind:  Document_Highlight_Kind,
}

// handle_document_highlight implements textDocument/documentHighlight. It
// returns the occurrences of the symbol under the cursor within its document.
handle_document_highlight :: proc(srv: ^Server, id: Request_Id, obj: json.Object) -> (ok: bool) {
	params := json_object(obj, "params") or_return
	text_doc := json_object(params, "textDocument") or_return
	uri := json_string(text_doc, "uri") or_return
	pos := json_object(params, "position") or_return

	doc, found := srv.documents[uri]
	if !found {
		write_response(srv, id, "[]")
		return true
	}

	line := json_int(pos, "line") or_return
	character := json_int(pos, "character") or_return
	offset := offset_at_position(doc.text, Position{line = int(line), character = int(character)})

	cu := index_documents(srv)
	defer check.destroy_compilation_unit(&cu)

	fi, fi_ok := cu_file_for(srv, &cu, doc.uri)
	if !fi_ok {
		write_response(srv, id, "[]")
		return true
	}

	hit := find_hit(&fi.file, offset)
	target, target_ok := reference_target(&cu, fi, hit)
	if !target_ok {
		write_response(srv, id, "[]")
		return true
	}

	uris := build_file_uris(&cu)
	defer {
		for _, u in uris {
			delete(u)
		}
		delete(uris)
	}

	refs := make([dynamic]Location)
	defer {
		for r in refs {
			delete(r.uri)
		}
		delete(refs)
	}

	switch target.kind {
	case .Rule:
		collect_rule_refs(fi, target.ns_dir, target.name, true, uris, &refs)
	case .Binding:
		collect_binding_refs(fi, target.name, true, uris, &refs)
	case .Local_Rule:
		collect_rule_refs(fi, target.ns_dir, target.name, true, uris, &refs, true)
	case .Param:
		collect_param_refs(fi, target.decl, target.name, true, uris, &refs)
	}

	highlights := make([dynamic]Document_Highlight, len(refs))
	defer delete(highlights)
	for loc, i in refs {
		highlights[i] = Document_Highlight {
			range = loc.range,
			kind  = .Text,
		}
	}

	buf, err := json.marshal(highlights, allocator = context.temp_allocator)
	if err != nil {
		debugf(srv, "failed to marshal document highlights: %v", err)
		return false
	}

	write_response(srv, id, string(buf))
	return true
}
