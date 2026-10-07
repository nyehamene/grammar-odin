package lsp

import "core:encoding/json"
import "core:sort"
import "core:strings"

import "../../ast"
import "../check"

// Symbol_Ref_Kind discriminates what a symbol reference consists of.
Symbol_Ref_Kind :: enum {
	Rule,
	Private_Rule,
	Binding,
	Param,
}

// Symbol_Ref identifies a symbol whose references we want: either a rule living
// in a namespace directory, or a file-local import binding.
Symbol_Ref :: struct {
	kind:        Symbol_Ref_Kind,
	name:        string,
	ns_dir:      string, // for .Rule
	origin_file: ^check.Loaded_File, // for .Binding
	decl:        int, // for .Param
}

// handle_references implements textDocument/references. It finds every
// occurrence of the symbol under the cursor across all open documents and
// returns them as a list of Locations, honoring context.includeDeclaration.
handle_references :: proc(srv: ^Server, id: Request_Id, obj: json.Object) -> (ok: bool) {
	params := json_object(obj, "params") or_return
	text_doc := json_object(params, "textDocument") or_return
	uri := json_string(text_doc, "uri") or_return
	pos := json_object(params, "position") or_return
	line := json_int(pos, "line") or_return
	character := json_int(pos, "character") or_return

	include_declaration := false
	if ctx, ctx_ok := json_object(params, "context"); ctx_ok {
		if b, b_ok := json_bool(ctx, "includeDeclaration"); b_ok {
			include_declaration = b
		}
	}

	doc, found := srv.documents[uri]
	if !found {
		write_response(srv, id, "[]")
		return true
	}

	cu := index_documents(srv)
	defer check.destroy_compilation_unit(&cu)

	target_abs, abs_ok := uri_to_path(doc.uri)
	if !abs_ok {
		write_response(srv, id, "[]")
		return true
	}
	fi, fi_ok := cu.files[target_abs]
	delete(target_abs)
	if !fi_ok {
		write_response(srv, id, "[]")
		return true
	}

	offset := offset_at_position(doc.text, Position{line = int(line), character = int(character)})
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

	for _, f in cu.files {
		switch target.kind {
		case .Rule:
			if f.namespace_path == target.ns_dir {
				collect_rule_refs(f, target.ns_dir, target.name, include_declaration, uris, &refs)
			}
		case .Binding:
			if f == target.origin_file {
				collect_binding_refs(f, target.name, include_declaration, uris, &refs)
			}
		case .Private_Rule:
			if f == target.origin_file {
				collect_rule_refs(
					f,
					"",
					target.name,
					include_declaration,
					uris,
					&refs,
					private = true,
				)
			}

		case .Param:
			if f == target.origin_file {
				collect_param_refs(f, target.decl, target.name, include_declaration, uris, &refs)
			}
		}
	}

	sort.quick_sort_proc(refs[:], cmp_references)

	buf, err := json.marshal(refs, allocator = context.temp_allocator)
	if err != nil {
		debugf(srv, "failed to marshal references: %v", err)
		return false
	}

	write_response(srv, id, string(buf))
	return true
}

// reference_target resolves the symbol under the cursor to a namespace rule or
// a file-local import binding.
reference_target :: proc(
	cu: ^check.Compilation_Unit,
	fi: ^check.Loaded_File,
	hit: Hit,
) -> (
	Symbol_Ref,
	bool,
) {
	#partial switch hit.kind {
	case .Rule_Name:
		if _, ok := fi.private_rules[hit.ident.name]; ok {
			return Symbol_Ref{kind = .Private_Rule, name = hit.ident.name, origin_file = fi}, true
		}
		return Symbol_Ref{kind = .Rule, name = hit.ident.name, ns_dir = fi.namespace_path}, true
	case .Ident, .Call_Name:
		if _, is_binding := fi.bindings[hit.ident.name]; is_binding {
			return Symbol_Ref{kind = .Binding, name = hit.ident.name, origin_file = fi}, true
		}
		if _, ok := fi.private_rules[hit.ident.name]; ok {
			return Symbol_Ref{kind = .Private_Rule, name = hit.ident.name, origin_file = fi}, true
		}
		if _, ok := rule_ref_at(cu, fi, hit.ident.name); ok {
			return Symbol_Ref{kind = .Rule, name = hit.ident.name, ns_dir = fi.namespace_path},
				true
		}
	case .Binding_Name, .Member_Object:
		if _, is_binding := fi.bindings[hit.ident.name]; is_binding {
			return Symbol_Ref{kind = .Binding, name = hit.ident.name, origin_file = fi}, true
		}
	case .Member:
		if dir, is_binding := fi.bindings[hit.member_object]; is_binding {
			if _, _, ok := member_ref_at(cu, fi, hit); ok {
				return Symbol_Ref{kind = .Rule, name = hit.ident.name, ns_dir = dir}, true
			}
		}
	case .Param:
		return Symbol_Ref{kind = .Param, name = hit.ident.name, origin_file = fi, decl = hit.decl},
			true
	}
	return {}, false
}

// collect_rule_refs appends every occurrence of the rule named name (in the
// namespace directory target_ns_dir) inside file f: its declaration, term
// references, invocations and qualifying member accesses.
collect_rule_refs :: proc(
	f: ^check.Loaded_File,
	target_ns_dir, name: string,
	include_declaration: bool,
	uris: map[^check.Loaded_File]string,
	out: ^[dynamic]Location,
	private := false,
) {
	for decl in f.file.decls {
		#partial switch d in decl {
		case ast.Rule:
			if include_declaration && d.ident.name == name {
				push_reference(out, uris, f, d.ident.pos, d.ident.name)
			}
			rule_ref_in_production(f, target_ns_dir, name, d.production, uris, out, private)
		case ast.Binding, ast.Comment_Group:
		}
	}
}

// collect_binding_refs appends every occurrence of the file-local binding name
// inside file f: its declaration and the receiver idents that use it.
collect_binding_refs :: proc(
	f: ^check.Loaded_File,
	name: string,
	include_declaration: bool,
	uris: map[^check.Loaded_File]string,
	out: ^[dynamic]Location,
) {
	for decl in f.file.decls {
		#partial switch d in decl {
		case ast.Binding:
			if include_declaration && d.ident.name == name {
				push_reference(out, uris, f, d.ident.pos, d.ident.name)
			}
		case ast.Rule:
			binding_ref_in_production(f, name, d.production, uris, out)
		case ast.Comment_Group:
		}
	}
}

collect_param_refs :: proc(
	f: ^check.Loaded_File,
	index: int,
	name: string,
	include_declaration: bool,
	uris: map[^check.Loaded_File]string,
	out: ^[dynamic]Location,
) {
	if index >= len(f.file.decls) do return
	decl := f.file.decls[index]
	#partial switch d in decl {
	case ast.Rule:
		for p in d.params {
			rule_ref_in_production(f, "", name, p, uris, out, true)
		}
		rule_ref_in_production(f, "", name, d.production, uris, out, true)
	case ast.Comment_Group:
	}
}

rule_ref_in_production :: proc(
	f: ^check.Loaded_File,
	target_ns_dir, name: string,
	production: ast.Production,
	uris: map[^check.Loaded_File]string,
	out: ^[dynamic]Location,
	private: bool,
) {
	#partial switch v in production {
	case ast.Ident:
		if v.name == name {
			push_reference(out, uris, f, v.pos, v.name)
		}

	case ast.Qual_Ident:
		if private do break
		if dir, is_binding := f.bindings[v.lhs.name];
		   is_binding && dir == target_ns_dir && v.rhs.name == name {
			push_reference(out, uris, f, v.rhs.pos, v.rhs.name)
		}
	case ^ast.Call:
		switch it in v.ident {
		case ast.Ident:
			rule_ref_in_production(f, target_ns_dir, name, it, uris, out, private)
		case ast.Qual_Ident:
			rule_ref_in_production(f, target_ns_dir, name, it, uris, out, private)
		}
		for arg in v.args {
			rule_ref_in_production(f, target_ns_dir, name, arg, uris, out, private)
		}
	case ast.Sequence:
		for e in v.productions {
			rule_ref_in_production(f, target_ns_dir, name, e, uris, out, private)
		}
	case ast.Alternative:
		rule_ref_in_production(f, target_ns_dir, name, v.lhs^, uris, out, private)
		rule_ref_in_production(f, target_ns_dir, name, v.rhs^, uris, out, private)
	case ast.Optional:
		rule_ref_in_production(f, target_ns_dir, name, v.production^, uris, out, private)
	case ast.Repetition:
		rule_ref_in_production(f, target_ns_dir, name, v.production^, uris, out, private)
	case ast.Group:
		rule_ref_in_production(f, target_ns_dir, name, v.production^, uris, out, private)
	case ast.Directive:
		for arg in v.args {
			rule_ref_in_production(f, target_ns_dir, name, arg, uris, out, private)
		}
	case ast.Tagged_Production:
		rule_ref_in_production(f, target_ns_dir, name, v.production^, uris, out, private)
	case ast.String_Lit, ast.Regex_Lit, ast.External_Value:
	}
}

// binding_ref_in_production appends every identifier with the binding's name in production.
binding_ref_in_production :: proc(
	f: ^check.Loaded_File,
	name: string,
	production: ast.Production,
	uris: map[^check.Loaded_File]string,
	out: ^[dynamic]Location,
) {
	#partial switch v in production {
	case ast.Ident:
		if v.name == name {
			push_reference(out, uris, f, v.pos, v.name)
		}
	case ast.Qual_Ident:
		if v.lhs.name == name {
			push_reference(out, uris, f, v.lhs.pos, v.lhs.name)
		}
		if v.rhs.name == name {
			push_reference(out, uris, f, v.rhs.pos, v.rhs.name)
		}
	case ^ast.Call:
		switch it in v.ident {
		case ast.Ident:
			binding_ref_in_production(f, name, it, uris, out)
		case ast.Qual_Ident:
			binding_ref_in_production(f, name, it, uris, out)
		}
		for arg in v.args {
			binding_ref_in_production(f, name, arg, uris, out)
		}
	case ast.Sequence:
		for e in v.productions {
			binding_ref_in_production(f, name, e, uris, out)
		}
	case ast.Alternative:
		binding_ref_in_production(f, name, v.lhs^, uris, out)
		binding_ref_in_production(f, name, v.rhs^, uris, out)
	case ast.Optional:
		binding_ref_in_production(f, name, v.production^, uris, out)
	case ast.Repetition:
		binding_ref_in_production(f, name, v.production^, uris, out)
	case ast.Group:
		binding_ref_in_production(f, name, v.production^, uris, out)
	case ast.Directive:
		for arg in v.args {
			binding_ref_in_production(f, name, arg, uris, out)
		}
	case ast.Tagged_Production:
		binding_ref_in_production(f, name, v.production^, uris, out)
	case ast.String_Lit, ast.Regex_Lit, ast.External_Value:
	}
}

// push_reference converts an offset in target to a Location and appends it.
push_reference :: proc(
	out: ^[dynamic]Location,
	uris: map[^check.Loaded_File]string,
	target: ^check.Loaded_File,
	offset: int,
	name: string,
) {
	uri, found := uris[target]
	if !found {
		return
	}
	append(
		out,
		Location {
			uri = strings.clone(uri),
			range = Range {
				start = position_at_offset(target.src, offset),
				end = position_at_offset(target.src, offset + len(name)),
			},
		},
	)
}

// build_file_uris maps every loaded file to its file:// URI. The keys point
// into the compilation unit; the uri strings are owned by the map.
build_file_uris :: proc(cu: ^check.Compilation_Unit) -> map[^check.Loaded_File]string {
	uris := make(map[^check.Loaded_File]string)
	for abs, f in cu.files {
		uris[f] = path_to_uri(abs)
	}
	return uris
}

cmp_references :: proc(a, b: Location) -> int {
	if a.uri != b.uri {
		return -1 if a.uri < b.uri else 1
	}
	if a.range.start.line != b.range.start.line {
		return -1 if a.range.start.line < b.range.start.line else 1
	}
	if a.range.start.character != b.range.start.character {
		return -1 if a.range.start.character < b.range.start.character else 1
	}
	return 0
}
