package lsp

import "core:encoding/json"
import "core:strings"

import "../../ast"
import "../check"

// Location is an LSP location: a document URI and a range within it.
Location :: struct {
	uri:   string,
	range: Range,
}

// handle_definition implements textDocument/definition. It jumps from an
// identifier under the cursor to the file and offset where that rule or import
// binding is declared, returning a single Location (or null).
handle_definition :: proc(srv: ^Server, id: Request_Id, obj: json.Object) -> (ok: bool) {
	params := json_object(obj, "params") or_return
	text_doc := json_object(params, "textDocument") or_return
	uri := json_string(text_doc, "uri") or_return
	pos := json_object(params, "position") or_return
	line := json_int(pos, "line") or_return
	character := json_int(pos, "character") or_return

	doc, found := srv.documents[uri]
	if !found {
		write_response(srv, id, "null")
		return true
	}

	cu := index_documents(srv)
	defer check.destroy_compilation_unit(&cu)

	target_abs, abs_ok := uri_to_path(doc.uri)
	if !abs_ok {
		write_response(srv, id, "null")
		return true
	}
	fi, fi_ok := cu.files[target_abs]
	delete(target_abs)
	if !fi_ok {
		write_response(srv, id, "null")
		return true
	}

	offset := offset_at_position(doc.text, Position{line = int(line), character = int(character)})
	hit := find_hit(&fi.file, offset)

	loc, loc_ok := definition_for(&cu, fi, hit)
	if !loc_ok {
		write_response(srv, id, "null")
		return true
	}
	defer delete(loc.uri)

	buf, err := json.marshal(loc, allocator = context.temp_allocator)
	if err != nil {
		debugf(srv, "failed to marshal definition: %v", err)
		return false
	}

	write_response(srv, id, string(buf))
	return true
}

// definition_for resolves hit to the declaration of the referenced symbol: a
// rule declaration (in the same namespace or via a member access) or an import
// binding declaration.
definition_for :: proc(
	cu: ^check.Compilation_Unit,
	fi: ^check.Loaded_File,
	hit: Hit,
) -> (
	Location,
	bool,
) {
	target: ^check.Loaded_File
	target_offset := 0
	name_len := 0

	#partial switch hit.kind {
	case .Rule_Name, .Ident, .Call_Name:
		if ref, ok := rule_ref_at(cu, fi, hit.ident.name); ok {
			target = ref.file
			target_offset = ref.offset
			name_len = len(hit.ident.name)
		} else if _, is_binding := fi.bindings[hit.ident.name]; is_binding {
			if off, ok := fi.binding_offsets[hit.ident.name]; ok {
				target = fi
				target_offset = off
				name_len = len(hit.ident.name)
			}
		} else if r, is_local := fi.local_rules[hit.ident.name]; is_local {
			target = fi
			target_offset = r.offset
			name_len = len(hit.ident.name)
		}
	case .Binding_Name, .Member_Object:
		if off, ok := fi.binding_offsets[hit.ident.name]; ok {
			target = fi
			target_offset = off
			name_len = len(hit.ident.name)
		}
	case .Member:
		if file, off, ok := member_ref_at(cu, fi, hit); ok {
			target = file
			target_offset = off
			name_len = len(hit.ident.name)
		}
	case .Param:
		if hit.decl >= len(fi.file.decls) do break
		decl := fi.file.decls[hit.decl]
		d := decl.(ast.Rule_Decl) or_break
		loop: for p in d.params {
			if p.name == hit.ident.name {
				target = fi
				target_offset = p.pos
				name_len = len(hit.ident.name)
				break loop
			}
		}
	}

	if target == nil {
		return {}, false
	}

	abs, abs_ok := find_file_abs(cu, target)
	if !abs_ok {
		return {}, false
	}
	defer delete(abs)

	loc := Location {
		uri = path_to_uri(abs),
		range = Range {
			start = position_at_offset(target.src, target_offset),
			end = position_at_offset(target.src, target_offset + name_len),
		},
	}
	return loc, true
}

// member_ref_at resolves a member access such as `base.expr` to the rule's
// declaration in the namespace that object_name binds to.
member_ref_at :: proc(
	cu: ^check.Compilation_Unit,
	fi: ^check.Loaded_File,
	hit: Hit,
) -> (
	file: ^check.Loaded_File,
	offset: int,
	ok: bool,
) {
	if hit.member_object == "" {
		return nil, 0, false
	}
	dir, is_binding := fi.bindings[hit.member_object]
	if !is_binding {
		return nil, 0, false
	}
	ns := cu.namespaces[dir]
	if ns == nil {
		return nil, 0, false
	}
	ref, rule_found := ns.rules[hit.ident.name]
	if !rule_found {
		return nil, 0, false
	}
	return ref.file, ref.offset, true
}

// find_file_abs returns a clone of the absolute path that names target in cu.
find_file_abs :: proc(
	cu: ^check.Compilation_Unit,
	target: ^check.Loaded_File,
) -> (
	abs: string,
	ok: bool,
) {
	for key, f in cu.files {
		if f == target {
			return strings.clone(key), true
		}
	}
	return "", false
}
