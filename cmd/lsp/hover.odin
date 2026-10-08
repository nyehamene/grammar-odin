package lsp

import "core:encoding/json"
import "core:fmt"
import "core:path/filepath"
import "core:strings"

import "../../ast"
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
		// The name under the cursor *is* a declaration, and it may be a proc, so the hit
		// carries the arity it was declared at rather than it being resolved as a rule.
		return symbol_hover(cu, fi, hit.ident.name, hit.arity)
	case .Ident, .Call_Name:
		// A call names a proc of its own arity, which is what tells the procs of a
		// name apart, so the arity rides along with the hit.
		return symbol_hover(cu, fi, hit.ident.name, hit.arity)
	case .Binding_Name:
		return binding_hover(cu, fi, hit.ident.name)
	case .Member_Object:
		return binding_hover(cu, fi, hit.ident.name)
	case .Member:
		return member_hover(cu, fi, hit)
	}
	return ""
}

// symbol_hover describes a name in scope: the declaration of that arity, with its
// source, an import binding, or an unknown identifier.
symbol_hover :: proc(
	cu: ^check.Compilation_Unit,
	fi: ^check.Loaded_File,
	name: string,
	arity: int,
) -> string {
	if ref, found := private_at(cu, fi, name, arity); found {
		return declaration_hover(name, ref, private_location(ref.file, ref.offset))
	}
	if ref, found := resolve_at(cu, fi, name, arity); found {
		return declaration_hover(name, ref, location_string(ref.file, ref.offset))
	}
	if _, is_binding := fi.bindings[name]; is_binding {
		return binding_hover(cu, fi, name)
	}
	return fmt.tprintf("**identifier** `%s`", name)
}

// declaration_hover renders a declaration the way a hover reports it: what kind of
// declaration it is and under what name, where it is declared, and its own source.
//
// A proc of a name is one of several, and the arity is what tells them apart, so it is
// part of the name here for the same reason it is part of the arguments of a call.
// Without it `foo` and `foo/1` read as the same declaration.
//
// The source is fenced because the content is markdown and a declaration can contain a
// tag, which is written with backticks. Bare, those would be taken for inline code and
// the reader would see something the file does not say.
declaration_hover :: proc(name: string, ref: check.Rule_Ref, location: string) -> string {
	kind := fmt.tprintf("rule: %s", name)
	if ref.arity > 0 do kind = fmt.tprintf("proc: %s/%d", name, ref.arity)
	return fmt.tprintf(
		"%s\ndeclared at: %s\n\n```\n%s\n```",
		kind,
		location,
		decl_source(ref),
	)
}

// decl_source returns the source of the declaration ref points at: from its first token
// to the start of the next declaration, with trailing whitespace trimmed. There is no
// end offset on a declaration to work from, and this is the extent document_symbols
// already uses, so a hover and an outline agree on where a declaration begins and ends.
//
// It reads from the declaring file, so a hover on a name declared in a sibling file of
// the namespace shows that file's source rather than the one being hovered. The result
// is a view of the file's source and owns nothing.
decl_source :: proc(ref: check.Rule_Ref) -> string {
	file := &ref.file.file
	index, found := ast.Decl_Index_At(file, ref.offset)
	if !found do return ""

	start := ast.decl_pos(file.decls[index])
	end := len(ref.file.src)
	if index + 1 < len(file.decls) {
		end = ast.decl_pos(file.decls[index + 1])
	}
	return strings.trim_right(ref.file.src[start:end], " \t\r\n")
}

// private_location renders "line:column" for a private declaration, which is reachable
// only from the file that declares it, so the path would say nothing the line and
// column do not. A local rule is shared by every file of its namespace and may well be
// declared in another of them, so it keeps the path.
private_location :: proc(fi: ^check.Loaded_File, offset: int) -> string {
	pos := token.position_at(fi.src, offset)
	return fmt.tprintf("%d:%d", pos.line, pos.column)
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
	ref, found := ns.rules[hit.ident.name]
	if hit.arity > 0 {
		ref, found = check.Lookup_Proc(ns.procs[hit.ident.name], hit.arity)
	}
	if !found {
		return fmt.tprintf(
			"**member** `%s`\n\n**type:** member\n**namespace:** `%s`",
			hit.ident.name,
			filepath.base(target_dir),
		)
	}
	// The namespace the member came from is in the source below it, and the location
	// names the file it is declared in, so neither is repeated here.
	return declaration_hover(hit.ident.name, ref, location_string(ref.file, ref.offset))
}

// resolve_at resolves name to the declaration the checker would resolve it to: the
// rule of arity zero, or the proc of the given arity. It is the one place the server
// resolves a bare name, so hover, definition and the references all agree.
resolve_at :: proc(
	cu: ^check.Compilation_Unit,
	fi: ^check.Loaded_File,
	name: string,
	arity: int,
) -> (
	ref: check.Rule_Ref,
	found: bool,
) {
	if arity > 0 {
		ref, how := check.Resolve_Proc(cu, fi, name, arity)
		return ref, how == .Found
	}
	if ref, found := check.Resolve_Rule(cu, fi, name); found do return ref, true
	return {}, false
}

// private_at resolves name to the private declaration of that arity in fi, which is
// the one file-scoped lookup in the server: the checker resolves the private rules
// ahead of the namespace, and this keeps hover and definition matching it.
private_at :: proc(
	cu: ^check.Compilation_Unit,
	fi: ^check.Loaded_File,
	name: string,
	arity: int,
) -> (
	ref: check.Rule_Ref,
	found: bool,
) {
	if arity > 0 {
		for candidate in fi.private_procs[name] {
			if candidate.arity == arity do return candidate, true
		}
		return {}, false
	}
	rule, is_rule := fi.private_rules[name]
	return rule, is_rule
}

// location_string renders "path:line:column" for an offset within fi.
location_string :: proc(fi: ^check.Loaded_File, offset: int) -> string {
	pos := token.position_at(fi.src, offset)
	return fmt.tprintf("%s:%d:%d", fi.display, pos.line, pos.column)
}
