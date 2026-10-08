package lsp

import "core:encoding/json"
import "core:sort"
import "core:strings"

import "../../ast"
import "../check"

// Symbol_Information is the flat LSP workspace symbol result.
Symbol_Information :: struct {
	name:     string,
	kind:     Symbol_Kind,
	location: Location,
}

// handle_workspace_symbol implements workspace/symbol. It returns every rule
// and import binding across all open documents whose name contains the query.
handle_workspace_symbol :: proc(srv: ^Server, id: Request_Id, obj: json.Object) -> (ok: bool) {
	params := json_object(obj, "params") or_return
	query := json_string(params, "query") or_return

	cu := index_documents(srv)
	defer check.destroy_compilation_unit(&cu)

	uris := build_file_uris(&cu)
	defer {
		for _, u in uris {
			delete(u)
		}
		delete(uris)
	}

	symbols := make([dynamic]Symbol_Information)
	defer {
		for s in symbols {
			delete(s.location.uri)
		}
		delete(symbols)
	}

	for _, f in cu.files {
		for decl in f.file.decls {
			#partial switch d in decl {
			case ast.Rule:
				if query != "" && !strings.contains(d.ident.name, query) {
					continue
				}
				append(
					&symbols,
					symbol_information(completion_label(d), .Function, uris[f], f, d.ident.pos),
				)
			case ast.Binding:
				if query != "" && !strings.contains(d.ident.name, query) {
					continue
				}
				append(
					&symbols,
					symbol_information(d.ident.name, .Namespace, uris[f], f, d.ident.pos),
				)
			case ast.Comment_Group:
			}
		}
	}

	sort.quick_sort_proc(symbols[:], cmp_symbol_information)

	buf, err := json.marshal(symbols, allocator = context.temp_allocator)
	if err != nil {
		debugf(srv, "failed to marshal workspace symbols: %v", err)
		return false
	}

	write_response(srv, id, string(buf))
	return true
}

symbol_information :: proc(
	name: string,
	kind: Symbol_Kind,
	uri: string,
	f: ^check.Loaded_File,
	offset: int,
) -> Symbol_Information {
	return Symbol_Information {
		name = name,
		kind = kind,
		location = Location {
			uri = strings.clone(uri),
			range = Range {
				start = position_at_offset(f.src, offset),
				end = position_at_offset(f.src, offset + len(name)),
			},
		},
	}
}

cmp_symbol_information :: proc(a, b: Symbol_Information) -> int {
	if a.name != b.name {
		return -1 if a.name < b.name else 1
	}
	if a.location.uri != b.location.uri {
		return -1 if a.location.uri < b.location.uri else 1
	}
	if a.location.range.start.line != b.location.range.start.line {
		return -1 if a.location.range.start.line < b.location.range.start.line else 1
	}
	if a.location.range.start.character != b.location.range.start.character {
		return -1 if a.location.range.start.character < b.location.range.start.character else 1
	}
	return 0
}
