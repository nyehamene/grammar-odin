package lsp

import "core:encoding/json"
import "core:strings"

import "../check"

// Text_Edit is a single replacement inside a document.
Text_Edit :: struct {
	range:    Range,
	new_text: string `json:"newText"`,
}

// Workspace_Edit holds per-document edits.
Workspace_Edit :: struct {
	changes: map[string][dynamic]Text_Edit `json:"changes,omitempty"`,
}

// Prepare_Rename_Result tells the client the range and placeholder of the
// symbol that is about to be renamed.
Prepare_Rename_Result :: struct {
	range:       Range,
	placeholder: string,
}

// handle_prepare_rename implements textDocument/prepareRename. It returns the
// word under the cursor when it can be renamed, and null otherwise.
handle_prepare_rename :: proc(srv: ^Server, id: Request_Id, obj: json.Object) -> (ok: bool) {
	params := json_object(obj, "params") or_return
	uri := rename_document_uri(params) or_return

	doc, found := srv.documents[uri]
	if !found {
		write_response(srv, id, "null")
		return true
	}

	offset := rename_position_offset(params, doc) or_return

	cu := index_documents(srv)
	defer check.destroy_compilation_unit(&cu)

	fi, fi_ok := cu_file_for(srv, &cu, doc.uri)
	if !fi_ok {
		write_response(srv, id, "null")
		return true
	}

	hit := find_hit(&fi.file, offset)
	if _, target_ok := reference_target(&cu, fi, hit); !target_ok {
		write_response(srv, id, "null")
		return true
	}

	result := Prepare_Rename_Result {
		range = Range {
			start = position_at_offset(doc.text, hit.ident.pos),
			end = position_at_offset(doc.text, hit.ident.pos + len(hit.ident.name)),
		},
		placeholder = hit.ident.name,
	}

	buf, err := json.marshal(result, allocator = context.temp_allocator)
	if err != nil {
		debugf(srv, "failed to marshal prepare rename result: %v", err)
		return false
	}

	write_response(srv, id, string(buf))
	return true
}

// handle_rename implements textDocument/rename. It rewrites every occurrence
// of the symbol under the cursor in all open documents.
handle_rename :: proc(srv: ^Server, id: Request_Id, obj: json.Object) -> (ok: bool) {
	params := json_object(obj, "params") or_return
	uri := rename_document_uri(params) or_return
	new_name := json_string(params, "newName") or_return

	doc, found := srv.documents[uri]
	if !found {
		write_response(srv, id, `{"changes":{}}`)
		return true
	}

	offset := rename_position_offset(params, doc) or_return

	cu := index_documents(srv)
	defer check.destroy_compilation_unit(&cu)

	fi, fi_ok := cu_file_for(srv, &cu, doc.uri)
	if !fi_ok {
		write_response(srv, id, `{"changes":{}}`)
		return true
	}

	hit := find_hit(&fi.file, offset)
	target, target_ok := reference_target(&cu, fi, hit)
	if !target_ok {
		write_response(srv, id, `{"changes":{}}`)
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

	for _, f in cu.files {
		switch target.kind {
		case .Rule:
			if f.namespace_path == target.ns_dir {
				collect_rule_refs(f, target.ns_dir, target.name, true, uris, &refs)
			}
		case .Binding:
			if f == target.origin_file {
				collect_binding_refs(f, target.name, true, uris, &refs)
			}
		case .Private_Rule:
			if f == target.origin_file {
				collect_rule_refs(f, "", target.name, true, uris, &refs, true)
			}
		case .Param:
			if f == target.origin_file {
				collect_param_refs(f, target.decl, target.name, true, uris, &refs)
			}
		}
	}

	changes := make(map[string][dynamic]Text_Edit)
	defer {
		for _, edits in changes {
			delete(edits)
		}
		delete(changes)
	}

	for loc in refs {
		edits := changes[loc.uri]
		append(&edits, Text_Edit{range = loc.range, new_text = new_name})
		changes[loc.uri] = edits
	}

	buf, err := json.marshal(Workspace_Edit{changes = changes}, allocator = context.temp_allocator)
	if err != nil {
		debugf(srv, "failed to marshal workspace edit: %v", err)
		return false
	}

	write_response(srv, id, string(buf))
	return true
}

// rename_document_uri extracts the textDocument.uri from rename params.
rename_document_uri :: proc(params: json.Object) -> (string, bool) {
	text_doc, ok := json_object(params, "textDocument")
	if !ok {
		return "", false
	}
	return json_string(text_doc, "uri")
}

// rename_position_offset extracts position and converts it to an offset.
rename_position_offset :: proc(params: json.Object, doc: ^Document) -> (int, bool) {
	pos, pos_ok := json_object(params, "position")
	if !pos_ok {
		return 0, false
	}
	line, line_ok := json_int(pos, "line")
	if !line_ok {
		return 0, false
	}
	character, char_ok := json_int(pos, "character")
	if !char_ok {
		return 0, false
	}
	return offset_at_position(doc.text, Position{line = int(line), character = int(character)}),
		true
}

// cu_file_for looks up the Loaded_File backing an open document's uri.
cu_file_for :: proc(
	srv: ^Server,
	cu: ^check.Compilation_Unit,
	uri: string,
) -> (
	^check.Loaded_File,
	bool,
) {
	target_abs, abs_ok := uri_to_path(uri)
	if !abs_ok {
		return nil, false
	}
	defer delete(target_abs)
	return cu.files[target_abs]
}
