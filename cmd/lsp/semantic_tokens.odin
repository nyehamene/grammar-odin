package lsp

import "core:encoding/json"

import "../../ast"
import "../../token"

// Semantic token type indices into the provider legend.
Sem_Token_Type :: enum int {
	Function  = 0,
	Parameter = 1,
	Namespace = 2,
	Property  = 3,
	String    = 4,
	Variable  = 5,
	Operator  = 6,
}

Semantic_Tokens_Legend :: struct {
	token_types:     []string `json:"tokenTypes"`,
	token_modifiers: []string `json:"tokenModifiers"`,
}

Semantic_Tokens_Options :: struct {
	legend: Semantic_Tokens_Legend `json:"legend"`,
	full:   bool `json:"full"`,
}

Semantic_Tokens :: struct {
	data: []int `json:"data"`,
}

// handle_semantic_tokens_full implements textDocument/semanticTokens/full. It
// returns delta-encoded (startLine, startCharacter, length, tokenType,
// tokenModifiers) quintuples for every significant token in the document.
handle_semantic_tokens_full :: proc(srv: ^Server, id: Request_Id, obj: json.Object) -> (ok: bool) {
	params := json_object(obj, "params") or_return
	text_doc := json_object(params, "textDocument") or_return
	uri := json_string(text_doc, "uri") or_return

	doc, found := srv.documents[uri]
	if !found {
		write_response(srv, id, `{"data":[]}`)
		return true
	}

	tokens, lex_errors := token.scan(doc.text)
	defer delete(tokens)
	defer delete(lex_errors)

	file, parse_errors := ast.parse_file(doc.text, tokens[:])
	defer ast.destroy_file(&file)
	defer delete(parse_errors)

	types := classify_offsets(&file)
	defer delete(types)

	data := make([dynamic]int, 0, 5 * len(tokens))
	defer delete(data)

	prev_line := 0
	prev_char := 0
	for tok in tokens {
		if tok.kind == .EOF {
			continue
		}
		length := tok.end - tok.start
		if length <= 0 {
			continue
		}
		pos := position_at_offset(doc.text, tok.start)

		type_index := semantic_token_type(tok, doc.text, types)
		if type_index == -1 {
			continue
		}

		append(&data, pos.line - prev_line)
		if pos.line == prev_line {
			append(&data, pos.character - prev_char)
		} else {
			append(&data, pos.character)
		}
		append(&data, length)
		append(&data, type_index)
		append(&data, 0)

		prev_line = pos.line
		prev_char = pos.character + length
	}

	buf, err := json.marshal(Semantic_Tokens{data = data[:]}, allocator = context.temp_allocator)
	if err != nil {
		debugf(srv, "failed to marshal semantic tokens: %v", err)
		return false
	}

	write_response(srv, id, string(buf))
	return true
}

// semantic_token_type picks the legend index for tok, or -1 to skip it.
semantic_token_type :: proc(tok: token.Token, src: string, types: map[int]Sem_Token_Type) -> int {
	#partial switch tok.kind {
	case .Ident:
		if t, ok := types[tok.start]; ok {
			return int(t)
		}
		return int(Sem_Token_Type.Function)
	case .String, .Regexp:
		return int(Sem_Token_Type.String)
	case .External:
		return int(Sem_Token_Type.Variable)
	case .Comment:
		return -1
	case .At:
		if has_ident_after(src, tok.end) {
			return -1
		}
		return int(Sem_Token_Type.Operator)
	case:
		return int(Sem_Token_Type.Operator)
	}
}

// has_ident_after reports whether an identifier lexeme immediately follows.
has_ident_after :: proc(src: string, offset: int) -> bool {
	return offset < len(src) && is_ident_byte(src[offset])
}

// classify_offsets walks the AST, mapping every identifier offset to its
// semantic token type.
classify_offsets :: proc(file: ^ast.File) -> map[int]Sem_Token_Type {
	types := make(map[int]Sem_Token_Type)
	for decl in file.decls {
		#partial switch d in decl {
		case ast.Rule_Decl:
			types[d.name.pos] = .Function
			for p in d.params {
				types[p.pos] = .Parameter
			}
			for e in d.body {
				classify_expr(e, &types)
			}
		case ast.Binding_Decl:
			types[d.name.pos] = .Namespace
		case ast.Comment_Group:
		}
	}
	return types
}

classify_expr :: proc(expr: ast.Expr, types: ^map[int]Sem_Token_Type) {
	#partial switch v in expr {
	case ast.Ident:
		types^[v.pos] = .Function
	case ast.Term_Expr:
		classify_expr(v.x^, types)
	case ast.Member_Expr:
		classify_object(v.object^, types)
		types^[v.member.pos] = .Property
	case ^ast.Call_Expr:
		classify_expr(v.name, types)
		for arg in v.args {
			classify_expr(arg, types)
		}
	case ast.Sequence_Expr:
		for e in v.exprs {
			classify_expr(e, types)
		}
	case ast.Alternative_Expr:
		for e in v.exprs {
			classify_expr(e, types)
		}
	case ast.Optional_Expr:
		for e in v.exprs {
			classify_expr(e, types)
		}
	case ast.Repetition_Expr:
		for e in v.exprs {
			classify_expr(e, types)
		}
	case ast.Group_Expr:
		for e in v.exprs {
			classify_expr(e, types)
		}
	case ast.Directive_Expr:
		for arg in v.args {
			classify_expr(arg, types)
		}
	case ast.String_Lit, ast.Regex_Lit, ast.External_Value:
	}
}

// classify_object marks an expression used as a member receiver: a bare
// binding name, or further member access.
classify_object :: proc(expr: ast.Expr, types: ^map[int]Sem_Token_Type) {
	#partial switch v in expr {
	case ast.Ident:
		types^[v.pos] = .Namespace
	case ast.Member_Expr:
		classify_object(v.object^, types)
		types^[v.member.pos] = .Property
	case:
	}
}
