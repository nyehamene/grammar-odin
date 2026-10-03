package lsp

import "core:encoding/json"
import "core:fmt"
import "core:path/filepath"

import "../../token"
import "../check"

// Markup_Content carries a markdown string for hover and signature help.
Markup_Content :: struct {
	kind:  string, // "markdown"
	value: string,
}

// Hover is the response payload of textDocument/hover.
Hover :: struct {
	contents: Markup_Content,
}

// handle_hover implements textDocument/hover. It reports the kind of token
// under the cursor and, for identifiers, where the referenced rule or import
// binding is declared.
handle_hover :: proc(srv: ^Server, id: Request_Id, obj: json.Object) -> (ok: bool) {
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
	content := hover_for(&cu, fi, offset)
	if content == "" {
		write_response(srv, id, "null")
		return true
	}

	result := Hover {
		contents = Markup_Content{kind = "markdown", value = content},
	}
	buf, err := json.marshal(result, allocator = context.temp_allocator)
	if err != nil {
		debugf(srv, "failed to marshal hover: %v", err)
		return false
	}

	write_response(srv, id, string(buf))
	return true
}

// hover_for renders the hover text for the token containing offset.
// fi is the loaded file whose AST was parsed from the same source as offset.
hover_for :: proc(cu: ^check.Compilation_Unit, fi: ^check.Loaded_File, offset: int) -> string {
	hit := find_hit(&fi.file, offset)
	#partial switch hit.kind {
	case .None:
		return ""
	case .String:
		return "**type:** string literal"
	case .Regex:
		return "**type:** regular expression"
	case .External:
		return fmt.tprintf("**type:** external value `%s`", hit.literal)
	case .Directive:
		return fmt.tprintf("**type:** directive `@%s`", hit.ident.name)
	case .Param:
		return fmt.tprintf("**type:** proc parameter `%s`", hit.ident.name)
	case .Rule_Name:
		return symbol_hover(cu, fi, hit.ident.name)
	case .Ident, .Call_Name:
		return symbol_hover(cu, fi, hit.ident.name)
	case .Binding_Name:
		return binding_hover(cu, fi, hit.ident.name)
	case .Member_Object:
		return binding_hover(cu, fi, hit.ident.name)
	case .Member:
		return member_hover(cu, fi, hit)
	}
	return ""
}

// symbol_hover describes a name in scope: a rule in the file's namespace, an
// import binding, or an unknown identifier. It reports the type of the value
// the name produces.
symbol_hover :: proc(cu: ^check.Compilation_Unit, fi: ^check.Loaded_File, name: string) -> string {
	if ref, ok := rule_ref_at(cu, fi, name); ok {
		return fmt.tprintf(
			"**`%s`**\n\n**type:** %s\n**declared at:** `%s`",
			name,
			type_doc(ref),
			location_string(ref.file, ref.offset),
		)
	}
	if r, is_private := fi.private_rules[name]; is_private {
		pos := token.position_at(fi.src, r.offset)
		return fmt.tprintf(
			"**`%s`**\n\n**type:** %s\n**declared at:** `%d:%d`",
			name,
			type_doc(r),
			pos.line,
			pos.column,
		)
	}
	if _, is_binding := fi.bindings[name]; is_binding {
		return binding_hover(cu, fi, name)
	}
	return fmt.tprintf("**identifier** `%s`", name)
}

// binding_hover describes an import binding and the namespace it points at.
binding_hover :: proc(
	cu: ^check.Compilation_Unit,
	fi: ^check.Loaded_File,
	name: string,
) -> string {
	dir, found := fi.bindings[name]
	if !found {
		return fmt.tprintf("**identifier** `%s`", name)
	}
	if off, off_found := fi.binding_offsets[name]; off_found {
		return fmt.tprintf(
			"**`%s`**\n\n**type:** namespace import\n**namespace:** `%s`\n**declared at:** `%s`",
			name,
			filepath.base(dir),
			location_string(fi, off),
		)
	}
	return fmt.tprintf(
		"**`%s`**\n\n**type:** namespace import\n**namespace:** `%s`",
		name,
		filepath.base(dir),
	)
}

// member_hover describes a member access such as `base.expr`.
member_hover :: proc(cu: ^check.Compilation_Unit, fi: ^check.Loaded_File, hit: Hit) -> string {
	if hit.member_object == "" {
		return fmt.tprintf("**member** `%s`\n\n**type:** member", hit.ident.name)
	}
	target_dir, object_binding := fi.bindings[hit.member_object]
	if !object_binding {
		return fmt.tprintf("**member** `%s`\n\n**type:** member", hit.ident.name)
	}
	ns := cu.namespaces[target_dir]
	if ns == nil {
		return fmt.tprintf("**member** `%s`\n\n**type:** member", hit.ident.name)
	}
	// Only an exported rule is reachable through a binding.
	if !check.is_exported_rule(hit.ident.name) {
		return fmt.tprintf(
			"**member** `%s`\n\n**type:** member\n**namespace:** `%s`",
			hit.ident.name,
			filepath.base(target_dir),
		)
	}
	ref, rule_found := ns.rules[hit.ident.name]
	if !rule_found {
		return fmt.tprintf(
			"**member** `%s`\n\n**type:** member\n**namespace:** `%s`",
			hit.ident.name,
			filepath.base(target_dir),
		)
	}
	return fmt.tprintf(
		"**member** `%s`\n\n**type:** member — %s\n**namespace:** `%s`\n**declared at:** `%s`",
		type_doc(ref),
		hit.ident.name,
		filepath.base(target_dir),
		location_string(ref.file, ref.offset),
	)
}

// rule_ref_at resolves name to the Rule_Ref of its declaration in the file's
// own namespace.
rule_ref_at :: proc(
	cu: ^check.Compilation_Unit,
	fi: ^check.Loaded_File,
	name: string,
) -> (
	ref: check.Rule_Ref,
	found: bool,
) {
	ns := cu.namespaces[fi.namespace_path]
	if ns == nil {
		return {}, false
	}
	rule, ok := ns.rules[name]
	return rule, ok
}

// location_string renders "path:line:column" for an offset within fi.
location_string :: proc(fi: ^check.Loaded_File, offset: int) -> string {
	pos := token.position_at(fi.src, offset)
	return fmt.tprintf("%s:%d:%d", fi.display, pos.line, pos.column)
}
