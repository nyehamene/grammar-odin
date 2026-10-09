package lsp

import "core:encoding/json"
import "core:fmt"
import "core:sort"
import "core:strings"

import "../../ast"
import "../check"

// Completion_Item_Kind mirrors the LSP CompletionItemKind enum values.
Completion_Item_Kind :: enum {
	Text           = 1,
	Method         = 2,
	Function       = 3,
	Constructor    = 4,
	Field          = 5,
	Variable       = 6,
	Class          = 7,
	Interface      = 8,
	Module         = 9,
	Property       = 10,
	Unit           = 11,
	Value          = 12,
	Enum           = 13,
	Keyword        = 14,
	Snippet        = 15,
	Color          = 16,
	File           = 17,
	Reference      = 18,
	Folder         = 19,
	Enum_Member    = 20,
	Constant       = 21,
	Struct         = 22,
	Event          = 23,
	Operator       = 24,
	Type_Parameter = 25,
}

Completion_Item :: struct {
	label: string,
	kind:  Completion_Item_Kind,
	// detail says what the item is when the label does not: a proc's arity, so that
	// `foo`, `foo(x)` and `foo(x, y)` are three items rather than one.
	detail: string `json:"detail,omitempty"`,
	// text_edit is what the editor inserts, which is not the label. A proc's label
	// carries its parameter list to tell the procs of one name apart in the list, and
	// `foo(x)` is not grammar, so the label is not what belongs in the document. A
	// rule is completed by its bare name and a proc by a call naming it.
	text_edit: Text_Edit `json:"textEdit,omitempty"`,
	// insert_text_format tells the client how to read new_text: 1 for plain text, 2 for a
	// snippet whose ${n} tab stops become places it can jump between. It is always
	// written out, because the spec has no zero and this Odin's `omitempty` does not drop
	// a zero integer, so leaving it out is not something the tag can do.
	insert_text_format: int `json:"insertTextFormat"`,
}

// completion_label is what a declaration is offered as: a rule by its name, and a
// proc by its name and its parameter list, so the procs of one name are told apart in
// the list the way they are told apart by a call.
completion_label :: proc(d: ast.Rule) -> string {
	if len(d.params) == 0 do return d.ident.name

	sb := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&sb)
	strings.write_string(&sb, d.ident.name)
	strings.write_string(&sb, "(")
	for p, i in d.params {
		if i > 0 do strings.write_string(&sb, ", ")
		strings.write_string(&sb, p.name)
	}
	strings.write_string(&sb, ")")
	return strings.to_string(sb)
}

// completion_detail says the arity of a proc, since that is what a call has to match.
completion_detail :: proc(d: ast.Rule) -> string {
	if len(d.params) == 0 do return ""
	return fmt.tprintf("proc, %d parameter%s", len(d.params), plural(len(d.params)))
}

Completion_List :: struct {
	is_incomplete: bool `json:"isIncomplete"`,
	items:         []Completion_Item,
}

// The LSP InsertTextFormat values, which say how a client should read what a completion
// inserts: plain text, or a snippet whose tab stops it can jump between.
PLAIN_TEXT_FORMAT :: 1
SNIPPET_FORMAT    :: 2

// completion_edit builds what accepting an item puts in the document, over the span the
// prefix being typed occupies.
//
// A rule is completed by its name, which is how a rule is written in a body. A proc is
// completed by a call naming it, since `foo(x)` is not grammar and a proc cannot stand
// in a body on its own. Inside a call the angle brackets are already typed, so only the
// callee and its arguments are written; outside one they are added. The tab stops mark
// the argument positions when the client takes snippets, and are dropped when it does
// not, since an unrecognised ${n} would be inserted as text.
completion_edit :: proc(
	srv: ^Server,
	src: string,
	prefix: string,
	prefix_pos: int,
	end_pos: int,
	d: ast.Rule,
	inside_call: bool,
) -> (edit: Text_Edit, format: int) {
	span := Range {
		start = position_at_offset(src, prefix_pos),
		end   = position_at_offset(src, end_pos),
	}
	if len(d.params) == 0 {
		return Text_Edit{range = span, new_text = d.ident.name}, PLAIN_TEXT_FORMAT
	}

	sb := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&sb)
	if !inside_call do strings.write_string(&sb, "<")
	strings.write_string(&sb, d.ident.name)
	for p, i in d.params {
		strings.write_string(&sb, " ")
		if srv.snippet_support {
			// The tab stop is written out by hand rather than formatted, because tprintf
			// reads a `{` as the start of a placeholder and would eat this one's braces.
			strings.write_string(&sb, "${")
			strings.write_string(&sb, fmt.tprintf("%d", i + 1))
			strings.write_string(&sb, ":")
			strings.write_string(&sb, p.name)
			strings.write_string(&sb, "}")
		} else {
			strings.write_string(&sb, p.name)
		}
	}
	if !inside_call do strings.write_string(&sb, ">")

	if srv.snippet_support {
		return Text_Edit{range = span, new_text = strings.to_string(sb)}, SNIPPET_FORMAT
	}
	return Text_Edit{range = span, new_text = strings.to_string(sb)}, PLAIN_TEXT_FORMAT
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
		write_response(srv, id, `{"isIncomplete":false,"items":[]}`)
		return true
	}

	line := json_int(pos, "line") or_return
	character := json_int(pos, "character") or_return
	offset := offset_at_position(doc.text, Position{line = int(line), character = int(character)})

	prefix, prefix_pos, member_object := completion_prefix(doc.text, offset)

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
		write_response(srv, id, `{"isIncomplete":false,"items":[]}`)
		return true
	}

	items := make([dynamic]Completion_Item)
	defer delete(items)

	// A proc is completed as a call, and the angle brackets of that call are already
	// typed when the cursor sits inside one, so the two cases insert different text.
	inside_call := containing_call(&fi.file, doc.text, offset) != nil

	if member_object != "" {
		dir := fi.bindings[member_object]
		if dir != "" {
			for _, f in cu.files {
				if f.namespace_path == dir {
					for decl in f.file.decls {
						#partial switch d in decl {
						case ast.Rule:
							// Only an exported rule is reachable through a
							// binding, so offering a local or private one from
							// another namespace would suggest a name that cannot
							// be used there.
							if !check.is_exported_rule(d.ident.name) do continue
							if strings.has_prefix(d.ident.name, prefix) {
								edit, format := completion_edit(
									srv,
									doc.text,
									prefix,
									prefix_pos,
									offset,
									d,
									inside_call,
								)
								append(
									&items,
									Completion_Item {
										label = completion_label(d),
										kind = .Function,
										detail = completion_detail(d),
										text_edit = edit,
										insert_text_format = format,
									},
								)
							}
						case ast.Binding, ast.Comment_Group:
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
				case ast.Rule:
					// The label carries the arity of a proc, so the procs of one
					// name are separate items and none of them is a duplicate of
					// another.
					label := completion_label(d)
					if strings.has_prefix(d.ident.name, prefix) && !has_label(items[:], label) {
						edit, format := completion_edit(
							srv,
							doc.text,
							prefix,
							prefix_pos,
							offset,
							d,
							inside_call,
						)
						append(
							&items,
							Completion_Item {
								label = label,
								kind = .Function,
								detail = completion_detail(d),
								text_edit = edit,
								insert_text_format = format,
							},
						)
					}
				case ast.Binding:
					if f != fi {
						continue
					}
					if strings.has_prefix(d.ident.name, prefix) &&
					   !has_label(items[:], d.ident.name) {
						// An import binding is a name, not something to call, so it is
						// completed by that name over the same span a rule's would be.
						append(
							&items,
							Completion_Item {
								label = d.ident.name,
								kind = .Module,
								text_edit = Text_Edit {
									range = Range {
										start = position_at_offset(doc.text, prefix_pos),
										end   = position_at_offset(doc.text, offset),
									},
									new_text = d.ident.name,
								},
							},
						)
					}
				case ast.Comment_Group:
				}
			}
		}
	}

	sort.quick_sort_proc(items[:], cmp_completion_items)

	result := Completion_List {
		is_incomplete = false,
		items         = items[:],
	}
	buf, err := json.marshal(result, allocator = context.temp_allocator)
	if err != nil {
		debugf(srv, "failed to marshal completion list: %v", err)
		return false
	}

	write_response(srv, id, string(buf))
	return true
}

// completion_prefix returns the identifier being typed before the cursor, where that
// identifier begins, and, when the cursor follows `binding.`, the receiver binding name.
// The start offset is what the completion edit spans: it replaces exactly the characters
// typed so far and nothing around them.
completion_prefix :: proc(
	src: string,
	offset: int,
) -> (
	prefix: string,
	prefix_pos: int,
	member_object: string,
) {
	i := offset
	for i > 0 && is_ident_byte(src[i - 1]) {
		i -= 1
	}
	prefix = src[i:offset]
	prefix_pos = i
	if i > 1 && src[i - 1] == '.' {
		obj_end := i - 1
		j := obj_end
		for j > 0 && is_ident_byte(src[j - 1]) {
			j -= 1
		}
		member_object = src[j:obj_end]
	}
	return prefix, prefix_pos, member_object
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
