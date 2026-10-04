package lsp

import "core:encoding/json"
import "core:path/filepath"
import "core:strings"

import "../../ast"
import "../check"

// Document_Link mirrors the LSP DocumentLink object.
Document_Link :: struct {
	range:  Range,
	target: string `json:"target"`,
}

// handle_document_link implements textDocument/documentLink. It generates
// links for `@import` bindings to the imported grammar file.
handle_document_link :: proc(srv: ^Server, id: Request_Id, obj: json.Object) -> (ok: bool) {
	params := json_object(obj, "params") or_return
	text_doc := json_object(params, "textDocument") or_return
	uri := json_string(text_doc, "uri") or_return

	if _, found := srv.documents[uri]; !found {
		write_response(srv, id, "[]")
		return true
	}

	cu := index_documents(srv)
	defer check.destroy_compilation_unit(&cu)

	file_abs, abs_ok := uri_to_path(uri)
	if !abs_ok {
		write_response(srv, id, "[]")
		return true
	}
	fi, fi_ok := cu.files[file_abs]
	delete(file_abs)
	if !fi_ok {
		write_response(srv, id, "[]")
		return true
	}

	links := make([dynamic]Document_Link)
	defer {
		for l in links {
			delete(l.target)
		}
		delete(links)
	}

	for decl in fi.file.decls {
		#partial switch d in decl {
		case ast.Binding:
			rel := strip_quotes(d.path.value)
			if rel == "" {
				continue
			}
			target_abs, target_ok := resolve_import(file_abs, rel, &cu)
			if !target_ok {
				continue
			}
			start := position_at_offset(fi.src, d.path.pos)
			end := position_at_offset(fi.src, d.path.pos + len(d.path.value))
			append(
				&links,
				Document_Link {
					range = Range{start = start, end = end},
					target = path_to_uri(target_abs),
				},
			)
			delete(target_abs)
		case ast.Rule, ast.Comment_Group:
		}
	}

	buf, err := json.marshal(links, allocator = context.temp_allocator)
	if err != nil {
		debugf(srv, "failed to marshal document links: %v", err)
		return false
	}

	write_response(srv, id, string(buf))
	return true
}

// strip_quotes removes the surrounding quotes from a String_Lit value.
strip_quotes :: proc(value: string) -> string {
	if len(value) >= 2 && value[0] == '"' && value[len(value) - 1] == '"' {
		return value[1:len(value) - 1]
	}
	return value
}

// resolve_import resolves a relative import path against the importing file's
// directory, preferring the grammar extension used by the loaded files.
resolve_import :: proc(
	file_abs: string,
	rel: string,
	cu: ^check.Compilation_Unit,
) -> (
	target_abs: string,
	ok: bool,
) {
	last_slash := strings.last_index_byte(file_abs, '/')
	base_dir := file_abs[:last_slash] if last_slash >= 0 else file_abs

	joined, _ := filepath.join([]string{base_dir, rel})
	defer delete(joined)
	cand, _ := filepath.clean(joined)
	defer delete(cand)
	if _, loaded := cu.files[cand]; loaded {
		return strings.clone(cand), true
	}

	cand_grammar := strings.concatenate({cand, ".grammar"})
	defer delete(cand_grammar)
	if _, loaded := cu.files[cand_grammar]; loaded {
		return strings.clone(cand_grammar), true
	}
	return "", false
}
