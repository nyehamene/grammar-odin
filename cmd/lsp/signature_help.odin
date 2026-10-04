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
		if name, ref, found := resolve_named(cu, fi, call.name); found {
			sig := signature_for_ref(cu, fi, name, ref)
			sig.active_parameter = active_arg(call, offset)
			return sig, true
		}
	}

	hit := find_hit(&fi.file, offset)
	#partial switch hit.kind {
	case .Ident, .Rule_Name:
		return value_signature(cu, fi, hit.ident.name)
	case .Call_Name:
		return value_signature(cu, fi, hit.ident.name)
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

// value_signature describes name as a proc (arity and parameters) when it is a
// parameterized rule, or as a production otherwise.
value_signature :: proc(
	cu: ^check.Compilation_Unit,
	fi: ^check.Loaded_File,
	name: string,
) -> (
	Signature_Help,
	bool,
) {
	ref, found := resolve_rule_ref(cu, fi, name)
	if !found {
		return {}, false
	}
	return signature_for_ref(cu, fi, name, ref), true
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
				kind  = "markdown",
				value = fmt.tprintf("**type:** proc, %d parameter%s", ref.arity, plural(ref.arity)),
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
			documentation = Markup_Content {kind = "markdown", value = "**type:** proc parameter"},
		}
	}

	sig := Signature_Information {
		label = strings.to_string(sb),
		documentation = Markup_Content {
			kind  = "markdown",
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
			kind  = "markdown",
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
			kind  = "markdown",
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
	ref, rule_found := ns.rules[hit.ident.name]
	if !rule_found {
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
	expr: ast.Expr,
) -> (
	name: string,
	ref: check.Rule_Ref,
	ok: bool,
) {
	#partial switch v in expr {
	case ast.Ident:
		if r, found := resolve_rule_ref(cu, fi, v.name); found {
			return v.name, r, true
		}
		name = v.name
	case ast.Member_Expr:
		if obj, is_ident := v.object^.(ast.Ident); is_ident {
			if dir, bound := fi.bindings[obj.name]; bound {
				// Only an exported rule is reachable through a binding.
				if ns := cu.namespaces[dir]; ns != nil &&
					check.is_exported_rule(v.member.name) {
					if r, r_ok := ns.rules[v.member.name]; r_ok {
						return v.member.name, r, true
					}
				}
			}
		}
		name = v.member.name
	case ast.Tagged_Expr:
		return resolve_named(cu, fi, v.expr^)
	}
	return name, {}, false
}

// resolve_rule_ref finds the rule name in the file's private rules or namespace.
resolve_rule_ref :: proc(
	cu: ^check.Compilation_Unit,
	fi: ^check.Loaded_File,
	name: string,
) -> (
	check.Rule_Ref,
	bool,
) {
	if priv_rule, ok := fi.private_rules[name]; ok {
		return priv_rule, true
	}
	ns := cu.namespaces[fi.namespace_path]
	if ns == nil {
		return {}, false
	}
	ref, found := ns.rules[name]
	return ref, found
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
		case ast.Rule_Decl:
			if d.name.pos == ref.offset {
				return d.params[:ref.arity], true
			}
		}
	}
	return {}, false
}

// active_arg returns the index of the argument containing or preceding offset.
active_arg :: proc(call: ^ast.Call_Expr, offset: int) -> int {
	idx := 0
	for arg in call.args {
		if ast.expr_pos(arg) < offset {
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
containing_call :: proc(file: ^ast.File, src: string, offset: int) -> ^ast.Call_Expr {
	for decl in file.decls {
		#partial switch d in decl {
		case ast.Rule_Decl:
			if call := expr_containing_call(d.expr, src, offset); call != nil {
				return call
			}
		case ast.Binding_Decl:
			if call := expr_containing_call(d.directive, src, offset); call != nil {
				return call
			}
		case ast.Comment_Group:
		}
	}
	return nil
}

expr_containing_call :: proc(expr: ast.Expr, src: string, offset: int) -> ^ast.Call_Expr {
	#partial switch v in expr {
	case ^ast.Call_Expr:
		if call := expr_containing_call(v.name, src, offset); call != nil {
			return call
		}
		for arg in v.args {
			if call := expr_containing_call(arg, src, offset); call != nil {
				return call
			}
		}
		if offset >= v.pos && offset < call_end(src, v.pos) {
			return v
		}
	case ast.Member_Expr:
		return expr_containing_call(v.object^, src, offset)
	case ast.Sequence_Expr:
		return exprs_containing_call(v.exprs[:], src, offset)
	case ast.Alternative_Expr:
		return exprs_containing_call(v.exprs[:], src, offset)
	case ast.Optional_Expr:
		return exprs_containing_call(v.exprs[:], src, offset)
	case ast.Repetition_Expr:
		return exprs_containing_call(v.exprs[:], src, offset)
	case ast.Group_Expr:
		return exprs_containing_call(v.exprs[:], src, offset)
	case ast.Directive_Expr:
		for arg in v.args {
			if call := expr_containing_call(arg, src, offset); call != nil {
				return call
			}
		}
	case ast.Tagged_Expr:
		return expr_containing_call(v.expr^, src, offset)
	case ast.Ident, ast.String_Lit, ast.Regex_Lit, ast.External_Value:
	}
	return nil
}

exprs_containing_call :: proc(exprs: []ast.Expr, src: string, offset: int) -> ^ast.Call_Expr {
	for e in exprs {
		if call := expr_containing_call(e, src, offset); call != nil {
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
type_doc :: proc(ref: check.Rule_Ref) -> string {
	if ref.arity > 0 {
		return fmt.tprintf("proc, %d parameter%s, returns a production", ref.arity, plural(ref.arity))
	}
	return "production, returns a production"
}