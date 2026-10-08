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
	// arity is the declaration a reference points at: 0 for the rule of a name, and
	// the parameter count for a proc of it. The procs of a name are distinct
	// declarations, so a reference to one says nothing about the others.
	arity: int,
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
				collect_rule_refs(
					f,
					target.ns_dir,
					target.name,
					target.arity,
					include_declaration,
					uris,
					&refs,
				)
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
					target.arity,
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
			return Symbol_Ref {
				kind = .Private_Rule,
				name = hit.ident.name,
				arity = hit_arity_of_decl(&fi.file, hit),
				origin_file = fi,
			}, true
		}
		return Symbol_Ref{kind = .Rule, name = hit.ident.name, ns_dir = fi.namespace_path}, true
	case .Ident, .Call_Name:
		if _, is_binding := fi.bindings[hit.ident.name]; is_binding {
			return Symbol_Ref{kind = .Binding, name = hit.ident.name, origin_file = fi}, true
		}
		// A private name is file-scoped, so its references stay in the file that
		// declares it whether it is a rule or a proc of it.
		if _, is_private_rule := fi.private_rules[hit.ident.name]; is_private_rule {
			return Symbol_Ref {
				kind = .Private_Rule,
				name = hit.ident.name,
				arity = hit.arity,
				origin_file = fi,
			}, true
		}
		if len(fi.private_procs[hit.ident.name]) > 0 {
			return Symbol_Ref {
				kind = .Private_Rule,
				name = hit.ident.name,
				arity = hit.arity,
				origin_file = fi,
			}, true
		}
		if _, ok := resolve_at(cu, fi, hit.ident.name, hit.arity); ok {
			return Symbol_Ref {
				kind = .Rule,
				name = hit.ident.name,
				arity = hit.arity,
				ns_dir = fi.namespace_path,
			}, true
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

// ANY_ARITY is the arity collect_rule_refs reads as "this name at any arity", which is
// what a rename asks for.
ANY_ARITY :: -1

// hit_arity_of_decl reports the arity of the declaration whose own name sits at hit, so
// that a feature working from a declaration knows which overload of the name it is. A
// name in a body resolves by the arity of its use, but a name that *is* a declaration
// resolves to itself.
hit_arity_of_decl :: proc(file: ^ast.File, hit: Hit) -> int {
	for decl in file.decls {
		rule, is_rule := decl.(ast.Rule)
		if is_rule && rule.ident.pos == hit.ident.pos do return len(rule.params)
	}
	return 0
}

// collect_rule_refs appends every occurrence of the declaration name/arity (in the
// namespace directory target_ns_dir) inside file f: its declaration, term references,
// invocations and qualifying member accesses.
//
// arity below zero matches the name at any arity, which is what rename and document
// highlight want: the procs of a name are dispatched by arity, so renaming one of them
// alone would leave the other call sites calling an arity that is no longer declared.
collect_rule_refs :: proc(
	f: ^check.Loaded_File,
	target_ns_dir, name: string,
	arity: int,
	include_declaration: bool,
	uris: map[^check.Loaded_File]string,
	out: ^[dynamic]Location,
	private := false,
) {
	for decl in f.file.decls {
		#partial switch d in decl {
		case ast.Rule:
			if include_declaration && d.ident.name == name &&
			   (arity < 0 || len(d.params) == arity) {
				push_reference(out, uris, f, d.ident.pos, d.ident.name)
			}
			rule_ref_in_production(f, target_ns_dir, name, arity, d.production, uris, out, private)
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
		// A parameter reference is not a reference to a declaration of the namespace,
		// so the arity is left to match nothing of it.
		for p in d.params {
			rule_ref_in_production(f, "", name, ANY_ARITY, p, uris, out, true)
		}
		rule_ref_in_production(f, "", name, ANY_ARITY, d.production, uris, out, true)
	case ast.Comment_Group:
	}
}

rule_ref_in_production :: proc(
	f: ^check.Loaded_File,
	target_ns_dir, name: string,
	arity: int,
	production: ast.Production,
	uris: map[^check.Loaded_File]string,
	out: ^[dynamic]Location,
	private: bool,
) {
	#partial switch v in production {
	case ast.Ident:
		// A bare identifier names the rule of arity zero, so it is a reference to
		// that declaration and not to a proc of the same name.
		if v.name == name && (arity < 0 || arity == 0) {
			push_reference(out, uris, f, v.pos, v.name)
		}

	case ast.Qual_Ident:
		if private do break
		if dir, is_binding := f.bindings[v.lhs.name];
		   is_binding && dir == target_ns_dir && v.rhs.name == name &&
		   (arity < 0 || arity == 0) {
			push_reference(out, uris, f, v.rhs.pos, v.rhs.name)
		}
	case ^ast.Call:
		// A call reaches the proc of its own arity, which is what decides whether
		// this call is a reference to the declaration being collected.
		calls_at_arity := arity < 0 || len(v.args) == arity
		switch it in v.ident {
		case ast.Ident:
			if calls_at_arity && it.name == name {
				push_reference(out, uris, f, it.pos, it.name)
			}
		case ast.Qual_Ident:
			if private do break
			if dir, is_binding := f.bindings[it.lhs.name];
			   is_binding && dir == target_ns_dir && it.rhs.name == name && calls_at_arity {
				push_reference(out, uris, f, it.rhs.pos, it.rhs.name)
			}
		}
		for arg in v.args {
			rule_ref_in_production(f, target_ns_dir, name, arity, arg, uris, out, private)
		}
	case ast.Sequence:
		for e in v.productions {
			rule_ref_in_production(f, target_ns_dir, name, arity, e, uris, out, private)
		}
	case ^ast.Alternative:
		rule_ref_in_production(f, target_ns_dir, name, arity, v.lhs, uris, out, private)
		rule_ref_in_production(f, target_ns_dir, name, arity, v.rhs, uris, out, private)
	case ^ast.Optional:
		rule_ref_in_production(f, target_ns_dir, name, arity, v.production, uris, out, private)
	case ^ast.Repetition:
		rule_ref_in_production(f, target_ns_dir, name, arity, v.production, uris, out, private)
	case ^ast.Group:
		rule_ref_in_production(f, target_ns_dir, name, arity, v.production, uris, out, private)
	case ast.Directive:
		for arg in v.args {
			rule_ref_in_production(f, target_ns_dir, name, arity, arg, uris, out, private)
		}
	case ^ast.Tagged_Production:
		rule_ref_in_production(f, target_ns_dir, name, arity, v.production, uris, out, private)
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
	case ^ast.Alternative:
		binding_ref_in_production(f, name, v.lhs, uris, out)
		binding_ref_in_production(f, name, v.rhs, uris, out)
	case ^ast.Optional:
		binding_ref_in_production(f, name, v.production, uris, out)
	case ^ast.Repetition:
		binding_ref_in_production(f, name, v.production, uris, out)
	case ^ast.Group:
		binding_ref_in_production(f, name, v.production, uris, out)
	case ast.Directive:
		for arg in v.args {
			binding_ref_in_production(f, name, arg, uris, out)
		}
	case ^ast.Tagged_Production:
		binding_ref_in_production(f, name, v.production, uris, out)
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
