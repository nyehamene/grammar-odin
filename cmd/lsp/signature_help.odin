package lsp

import "core:encoding/json"
import "core:fmt"
import "core:strings"

import "../../ast"
import "../check"

// Signature_Help is the response payload of textDocument/signatureHelp.
Signature_Help :: struct {
	signatures:       []Signature_Information,
	active_signature: int `json:"activeSignature"`,
	active_parameter: int `json:"activeParameter"`,
}

// Signature_Information describes one callable signature.
Signature_Information :: struct {
	label:         string, // e.g. `greet(name, title)`
	documentation: Markup_Content, // the type of the value requested and its arity
	parameters:    []Parameter_Information,
}

// Parameter_Information describes a single proc parameter.
Parameter_Information :: struct {
	label:         string, // the parameter name
	documentation: Markup_Content,
}

// handle_signature_help implements textDocument/signatureHelp. Inside a rule
// call it describes the callee (the type of the requested value, and for procs
// the arity and parameter names); elsewhere it reports the type of the value
// under the cursor.
handle_signature_help :: proc(srv: ^Server, id: Request_Id, obj: json.Object) -> (ok: bool) {
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

	fi, fi_ok := cu_file_for(srv, &cu, doc.uri)
	if !fi_ok {
		write_response(srv, id, "null")
		return true
	}

	offset := offset_at_position(doc.text, Position{line = int(line), character = int(character)})

	help, sig_ok := signature_help_for(&cu, fi, doc.text, offset)
	if !sig_ok {
		write_response(srv, id, "null")
		return true
	}

	buf, err := json.marshal(help, allocator = context.temp_allocator)
	if err != nil {
		debugf(srv, "failed to marshal signature help: %v", err)
		return false
	}

	write_response(srv, id, string(buf))
	return true
}

// signature_help_for computes the signature help for offset within fi. When
// offset is inside a rule call the callee's signature is shown with the active
// parameter highlighted; otherwise the type of the value under the cursor is
// reported.
signature_help_for :: proc(
	cu: ^check.Compilation_Unit,
	fi: ^check.Loaded_File,
	src: string,
	offset: int,
) -> (
	help: Signature_Help,
	ok: bool,
) {
	if call := containing_call(&fi.file, src, offset); call != nil {
		// A call names a proc of its own arity, and a name may hold one per arity, so
		// every one of them is offered and the arguments pick which is active.
		switch it in call.ident {
		case ast.Ident:
			if sigs, found := proc_signatures(cu, fi, it.name); found {
				sigs.active_signature = active_signature(sigs, len(call.args))
				sigs.active_parameter = active_arg(call, offset)
				return sigs, true
			}
		case ast.Qual_Ident:
			if name, ref, found := resolve_named(cu, fi, it); found {
				sig := signature_for_ref(cu, fi, name, ref)
				sig.active_parameter = active_arg(call, offset)
				return sig, true
			}
		}
	}

	hit := find_hit(&fi.file, offset)
	#partial switch hit.kind {
	case .Ident, .Rule_Name:
		return value_signature(cu, fi, hit.ident.name, 0)
	case .Call_Name:
		return value_signature(cu, fi, hit.ident.name, hit.arity)
	case .Param:
		return type_help("proc parameter", hit.ident.name), true
	case .Member:
		return member_signature(cu, fi, hit)
	case .Member_Object, .Binding_Name:
		return type_help("namespace import", hit.ident.name), true
	case .String:
		return type_help("string literal"), true
	case .Regex:
		return type_help("regular expression"), true
	case .External:
		return type_help("external value", hit.literal), true
	case .Directive:
		return type_help("directive", hit.ident.name), true
	case .None:
	}
	return {}, false
}

// value_signature describes name as the proc of arity, or as the rule when nothing of
// that arity is declared. A bare identifier names the rule of arity zero, so a name
// that is only procs falls back to offering those rather than nothing at all.
value_signature :: proc(
	cu: ^check.Compilation_Unit,
	fi: ^check.Loaded_File,
	name: string,
	arity: int,
) -> (
	Signature_Help,
	bool,
) {
	if arity > 0 {
		return proc_signatures(cu, fi, name)
	}
	if ref, found := check.Resolve_Rule(cu, fi, name); found {
		return signature_for_ref(cu, fi, name, ref), true
	}
	return proc_signatures(cu, fi, name)
}

// proc_signatures returns one signature per proc declared as name, ascending by arity,
// and reports whether any is. The procs of a name are distinct declarations, so the
// editor offers all of them and marks the one active rather than picking for the user.
proc_signatures :: proc(
	cu: ^check.Compilation_Unit,
	fi: ^check.Loaded_File,
	name: string,
) -> (
	Signature_Help,
	bool,
) {
	ns := cu.namespaces[fi.namespace_path]
	declared := fi.private_procs[name]
	overloads := len(declared)
	if ns != nil && len(ns.procs[name]) > len(declared) {
		declared = ns.procs[name]
		overloads = len(declared)
	}
	if len(declared) == 0 do return {}, false

	// A slice cannot be grown after it is built, so the list is sized for the procs
	// and filled in place.
	sigs := make([]Signature_Information, len(declared), context.temp_allocator)
	for ref, i in declared {
		sigs[i] = proc_information(cu, fi, name, ref, overloads)
	}
	return Signature_Help{signatures = sigs, active_signature = 0, active_parameter = 0}, true
}

// proc_information renders one proc as a signature: `name(p1, p2, ...)` with every
// parameter, and a note of the arity and how many overloads the name has.
proc_information :: proc(
	cu: ^check.Compilation_Unit,
	fi: ^check.Loaded_File,
	name: string,
	ref: check.Rule_Ref,
	overloads: int,
) -> Signature_Information {
	params, found := rule_params(fi, ref)
	infos := make([]Parameter_Information, len(params), context.temp_allocator)
	for p, i in params {
		infos[i] = Parameter_Information {
			label = p.name,
			documentation = Markup_Content{kind = "markdown", value = "**type:** proc parameter"},
		}
	}

	sb := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&sb)
	strings.write_string(&sb, name)
	strings.write_string(&sb, "(")
	for p, i in params {
		if i > 0 do strings.write_string(&sb, ", ")
		strings.write_string(&sb, p.name)
	}
	strings.write_string(&sb, ")")

	return Signature_Information {
		label = strings.to_string(sb),
		documentation = Markup_Content {
			kind = "markdown",
			value = fmt.tprintf("**type:** %s", type_doc(ref, overloads)),
		},
		parameters = infos,
	}
}

// active_signature is the index of the signature whose arity is want, and the nearest
// one when the call passes a count no proc of that name declares, which is the case
// the checker reports as a call with no matching overload.
active_signature :: proc(help: Signature_Help, want: int) -> int {
	nearest := 0
	nearest_gap := 0
	for sig, i in help.signatures {
		arity, is_proc := signature_arity(sig)
		if !is_proc do continue
		if arity == want do return i

		gap := arity - want
		if gap < 0 do gap = -gap
		if nearest == 0 || gap < nearest_gap {
			nearest = i
			nearest_gap = gap
		}
	}
	return nearest
}

// signature_arity reads the arity back out of a signature label of the form `name(...)`
// by counting the parameters it lists.
signature_arity :: proc(sig: Signature_Information) -> (int, bool) {
	open := strings.index_byte(sig.label, '(')
	close := strings.index_byte(sig.label, ')')
	if open < 0 || close <= open + 1 do return 0, false

	count := 1
	for i in open + 1 ..< close {
		if sig.label[i] == ',' do count += 1
	}
	return count, true
}

// signature_for_ref builds a signature with the rule's type, and for procs the
// arity and parameter names.
signature_for_ref :: proc(
	cu: ^check.Compilation_Unit,
	fi: ^check.Loaded_File,
	name: string,
	ref: check.Rule_Ref,
) -> Signature_Help {
	if ref.arity > 0 {
		return proc_signature(cu, fi, name, ref)
	}
	return production_signature(name)
}

// proc_signature renders `name(p1, p2, ...)` with every parameter and the
// proc's arity.
proc_signature :: proc(
	cu: ^check.Compilation_Unit,
	fi: ^check.Loaded_File,
	name: string,
	ref: check.Rule_Ref,
) -> Signature_Help {
	params, p_ok := rule_params(fi, ref)
	if !p_ok {
		sig := Signature_Information {
			label = name,
			documentation = Markup_Content {
				kind = "markdown",
				value = fmt.tprintf(
					"**type:** proc, %d parameter%s",
					ref.arity,
					plural(ref.arity),
				),
			},
			parameters = []Parameter_Information{},
		}
		return single_signature_help(sig)
	}

	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, name)
	strings.write_string(&sb, "(")
	for p, i in params {
		if i > 0 {
			strings.write_string(&sb, ", ")
		}
		strings.write_string(&sb, p.name)
	}
	strings.write_string(&sb, ")")

	infos := make([]Parameter_Information, len(params), context.temp_allocator)
	for p, i in params {
		infos[i] = Parameter_Information {
			label = p.name,
			documentation = Markup_Content{kind = "markdown", value = "**type:** proc parameter"},
		}
	}

	sig := Signature_Information {
		label = strings.to_string(sb),
		documentation = Markup_Content {
			kind = "markdown",
			value = fmt.tprintf("**type:** %s", type_doc(ref)),
		},
		parameters = infos,
	}
	return single_signature_help(sig)
}

// production_signature describes a rule without parameters.
production_signature :: proc(name: string) -> Signature_Help {
	sig := Signature_Information {
		label = name,
		documentation = Markup_Content {
			kind = "markdown",
			value = fmt.tprintf("**type:** %s", type_doc({arity = 0})),
		},
		parameters = []Parameter_Information{},
	}
	return single_signature_help(sig)
}

// type_help reports the type of a value that is not a named rule.
type_help :: proc(value_type: string, name := "") -> Signature_Help {
	label := name
	if label == "" {
		label = value_type
	}
	sig := Signature_Information {
		label = label,
		documentation = Markup_Content {
			kind = "markdown",
			value = fmt.tprintf("**type:** %s", value_type),
		},
		parameters = []Parameter_Information{},
	}
	return single_signature_help(sig)
}

// single_signature_help wraps sig into a help result. The backing array of the
// signatures slice is heap allocated (temp allocator) rather than a stack
// compound literal, which would become a dangling pointer once the caller's
// frame is gone.
single_signature_help :: proc(sig: Signature_Information) -> Signature_Help {
	sigs := make([]Signature_Information, 1, context.temp_allocator)
	sigs[0] = sig
	result := Signature_Help {
		signatures       = sigs,
		active_signature = 0,
		active_parameter = 0,
	}
	return result
}

// member_signature describes a member access such as `base.rule`.
member_signature :: proc(
	cu: ^check.Compilation_Unit,
	fi: ^check.Loaded_File,
	hit: Hit,
) -> (
	Signature_Help,
	bool,
) {
	if hit.member_object == "" {
		return type_help("member", hit.ident.name), true
	}
	target_dir, object_binding := fi.bindings[hit.member_object]
	if !object_binding {
		return type_help("member", hit.ident.name), true
	}
	ns := cu.namespaces[target_dir]
	if ns == nil {
		return type_help("member", hit.ident.name), true
	}
	// A member of a call names a proc of the call's arity; a member of a production
	// names the rule, the same split a bare name is resolved by.
	ref, found := ns.rules[hit.ident.name]
	if hit.arity > 0 {
		ref, found = check.Lookup_Proc(ns.procs[hit.ident.name], hit.arity)
	}
	if !found {
		return type_help("member", hit.ident.name), true
	}
	return signature_for_ref(cu, fi, hit.ident.name, ref), true
}

// resolve_named resolves a call's callee or an identifier to the rule it
// refers to. Member accesses such as `ns.rule` are resolved through the
// binding's namespace.
resolve_named :: proc(
	cu: ^check.Compilation_Unit,
	fi: ^check.Loaded_File,
	production: ast.Production,
) -> (
	name: string,
	ref: check.Rule_Ref,
	ok: bool,
) {
	#partial switch v in production {
	case ast.Ident:
		if r, found := check.Resolve_Rule(cu, fi, v.name); found {
			return v.name, r, true
		}
		name = v.name
	case ast.Qual_Ident:
		if dir, bound := fi.bindings[v.lhs.name]; bound {
			// Only an exported rule is reachable through a binding.
			if ns := cu.namespaces[dir]; ns != nil && check.is_exported_rule(v.rhs.name) {
				if r, r_ok := ns.rules[v.rhs.name]; r_ok {
					return v.rhs.name, r, true
				}
			}
		}
		name = v.rhs.name
	case ^ast.Tagged_Production:
		return resolve_named(cu, fi, v.production)
	}
	return name, {}, false
}

// rule_params returns the parameter identifiers of the rule declared at ref.
rule_params :: proc(
	fi: ^check.Loaded_File,
	ref: check.Rule_Ref,
) -> (
	params: []ast.Ident,
	found: bool,
) {
	for decl in fi.file.decls {
		#partial switch d in decl {
		case ast.Rule:
			if d.ident.pos == ref.offset {
				return d.params[:ref.arity], true
			}
		}
	}
	return {}, false
}

// active_arg returns the index of the argument containing or preceding offset.
active_arg :: proc(call: ^ast.Call, offset: int) -> int {
	idx := 0
	for arg in call.args {
		if ast.production_pos(arg) < offset {
			idx += 1
		} else {
			break
		}
	}
	if idx >= len(call.args) {
		if len(call.args) > 0 {
			return len(call.args) - 1
		}
		return 0
	}
	return idx
}

// containing_call returns the innermost rule call whose span contains offset,
// or nil. It searches children before self so the deepest call wins.
containing_call :: proc(file: ^ast.File, src: string, offset: int) -> ^ast.Call {
	for decl in file.decls {
		#partial switch d in decl {
		case ast.Rule:
			if call := production_containing_call(d.production, src, offset); call != nil {
				return call
			}
		case ast.Binding:
			if call := production_containing_call(d.directive, src, offset); call != nil {
				return call
			}
		case ast.Comment_Group:
		}
	}
	return nil
}

production_containing_call :: proc(production: ast.Production, src: string, offset: int) -> ^ast.Call {
	#partial switch v in production {
	case ^ast.Call:
		call: ast.Production

		switch it in v.ident {
		case ast.Ident:
			call = it
		case ast.Qual_Ident:
			call = it
		}

		if call := production_containing_call(call, src, offset); call != nil {
			return call
		}
		for arg in v.args {
			if call := production_containing_call(arg, src, offset); call != nil {
				return call
			}
		}
		if offset >= v.pos && offset < call_end(src, v.pos) {
			return v
		}
	case ast.Qual_Ident:
		return production_containing_call(v.lhs, src, offset)
	case ast.Sequence:
		return productions_containing_call(v.productions, src, offset)
	case ^ast.Alternative:
		if call := production_containing_call(v.lhs, src, offset); call != nil {
			return call
		}
		return production_containing_call(v.rhs, src, offset)
	case ^ast.Optional:
		return production_containing_call(v.production, src, offset)
	case ^ast.Repetition:
		return production_containing_call(v.production, src, offset)
	case ^ast.Group:
		return production_containing_call(v.production, src, offset)
	case ast.Directive:
		for arg in v.args {
			if call := production_containing_call(arg, src, offset); call != nil {
				return call
			}
		}
	case ^ast.Tagged_Production:
		return production_containing_call(v.production, src, offset)
	case ast.Ident, ast.String_Lit, ast.Regex_Lit, ast.External_Value:
	}
	return nil
}

productions_containing_call :: proc(productions: []ast.Production, src: string, offset: int) -> ^ast.Call {
	for e in productions {
		if call := production_containing_call(e, src, offset); call != nil {
			return call
		}
	}
	return nil
}

// call_end returns the offset just past the `>` that closes the call starting
// at start, accounting for nested calls and quoted literals.
call_end :: proc(src: string, start: int) -> int {
	depth := 1
	i := start
	for i < len(src) {
		switch src[i] {
		case '<':
			depth += 1
		case '>':
			depth -= 1
			if depth == 0 {
				return i + 1
			}
		case '"', '\'':
			quote := src[i]
			i += 1
			for i < len(src) {
				if src[i] == '\\' && i + 1 < len(src) {
					i += 2
					continue
				}
				if src[i] == quote {
					break
				}
				i += 1
			}
		}
		i += 1
	}
	return len(src)
}

// plural returns "s" unless n is 1.
plural :: proc(n: int) -> string {
	return "s" if n != 1 else ""
}

// type_doc renders the value type description of the rule ref, e.g.
// "proc, 2 parameters, returns a production" or "production, returns a
// production". Callers prefix it with their own label (hover and signature
// help both render it as "**type:** ..." markdown).
type_doc :: proc(ref: check.Rule_Ref, overloads: int = 1) -> string {
	if ref.arity > 0 {
		out := fmt.tprintf("proc, %d parameter%s", ref.arity, plural(ref.arity))
		if overloads > 1 {
			out = fmt.tprintf("%s, 1 of %d overloads", out, overloads)
		}
		return fmt.tprintf("%s, returns a production", out)
	}
	return "production, returns a production"
}
