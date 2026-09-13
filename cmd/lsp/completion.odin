package lsp

import "core:encoding/json"
import "core:sort"
import "core:strings"

import "../../ast"
import "../check"

// Completion_Item_Kind mirrors the LSP CompletionItemKind enum values.
Completion_Item_Kind :: enum {
	Text = 1,
	Method = 2,
	Function = 3,
	Constructor = 4,
	Field = 5,
	Variable = 6,
	Class = 7,
	Interface = 8,
	Module = 9,
	Property = 10,
	Unit = 11,
	Value = 12,
	Enum = 13,
	Keyword = 14,
	Snippet = 15,
	Color = 16,
	File = 17,
	Reference = 18,
	Folder = 19,
	Enum_Member = 20,
	Constant = 21,
	Struct = 22,
	Event = 23,
	Operator = 24,
	Type_Parameter = 25,
}

Completion_Item :: struct {
	label: string,
	kind:  Completion_Item_Kind,
}

Completion_List :: struct {
	is_incomplete: bool              `json:"isIncomplete"`,
	items:         []Completion_Item,
}

// handle_completion implements textDocument/completion. It suggests the rules
// of the current namespace, the file-local imports, and the members of an
// imported namespace after `binding.`.
handle_completion :: proc(srv: ^Server, id: Request_Id, obj: json.Object) -> (ok: bool) {
	params := json_object(obj, "params") or_return
	text_doc := json_object(params, "textDocument") or_return
	uri := json_string(text_doc, "uri") or_return
	pos := json_object(params, "position") or_return

	doc, found := srv.documents[uri]
	if !found {
		write_response(srv.stdout, id, `{"isIncomplete":false,"items":[]}`)
		return true
	}

	line := json_int(pos, "line") or_return
	character := json_int(pos, "character") or_return
	offset := offset_at_position(doc.text, Position{line = int(line), character = int(character)})

	prefix, member_object := completion_prefix(doc.text, offset)

	cu := index_documents(srv)
	defer check.destroy_compilation_unit(&cu)

	uris := build_file_uris(&cu)
	defer {
		for _, u in uris {
			delete(u)
		}
		delete(uris)
	}

	fi, fi_ok := cu_file_for(srv, &cu, doc.uri)
	if !fi_ok {
		write_response(srv.stdout, id, `{"isIncomplete":false,"items":[]}`)
		return true
	}

	items := make([dynamic]Completion_Item)
	defer delete(items)

	if member_object != "" {
		dir := fi.bindings[member_object]
		if dir != "" {
			for _, f in cu.files {
				if f.namespace_path == dir {
					for decl in f.file.decls {
						#partial switch d in decl {
						case ast.Rule_Decl:
							if strings.has_prefix(d.name.name, prefix) {
								append(&items, Completion_Item{label = d.name.name, kind = .Function})
							}
						case ast.Binding_Decl, ast.Comment_Group:
						}
					}
				}
			}
		}
	} else {
		for _, f in cu.files {
			if f.namespace_path != fi.namespace_path {
				continue
			}
			for decl in f.file.decls {
				#partial switch d in decl {
				case ast.Rule_Decl:
					if strings.has_prefix(d.name.name, prefix) && !has_label(items[:], d.name.name) {
						append(&items, Completion_Item{label = d.name.name, kind = .Function})
					}
				case ast.Binding_Decl:
					if f != fi {
						continue
					}
					if strings.has_prefix(d.name.name, prefix) && !has_label(items[:], d.name.name) {
						append(&items, Completion_Item{label = d.name.name, kind = .Module})
					}
				case ast.Comment_Group:
				}
			}
		}
	}

	sort.quick_sort_proc(items[:], cmp_completion_items)

	result := Completion_List{is_incomplete = false, items = items[:]}
	buf, err := json.marshal(result, allocator = context.temp_allocator)
	if err != nil {
		debugf(srv, "failed to marshal completion list: %v", err)
		return false
	}

	frame := write_response(srv.stdout, id, string(buf))
	debug(srv, frame)
	return true
}

// completion_prefix returns the identifier being typed before the cursor and,
// when the cursor follows `binding.`, the receiver binding name.
completion_prefix :: proc(src: string, offset: int) -> (prefix: string, member_object: string) {
	i := offset
	for i > 0 && is_ident_byte(src[i - 1]) {
		i -= 1
	}
	prefix = src[i:offset]
	if i > 1 && src[i - 1] == '.' {
		obj_end := i - 1
		j := obj_end
		for j > 0 && is_ident_byte(src[j - 1]) {
			j -= 1
		}
		member_object = src[j:obj_end]
	}
	return prefix, member_object
}

// has_label reports whether items already contains a label.
has_label :: proc(items: []Completion_Item, label: string) -> bool {
	for it in items {
		if it.label == label {
			return true
		}
	}
	return false
}

cmp_completion_items :: proc(a, b: Completion_Item) -> int {
	if a.label != b.label {
		return -1 if a.label < b.label else 1
	}
	return int(a.kind) - int(b.kind)
}