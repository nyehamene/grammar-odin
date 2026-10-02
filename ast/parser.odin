package ast

import "core:fmt"
import "core:log"

import "../token"

// Parser is a recursive descent parser over a tokenized grammar source.
Parser :: struct {
	src:        string,
	tokens:     []token.Token,
	pos:        int,
	errors:     [dynamic]Error,
	recovering: bool,
}

// parse_file parses the tokenized source into a File. Syntax diagnostics are
// appended to errors. If errors is non-empty the returned File may be partial.
parse_file :: proc(src: string, tokens: []token.Token) -> (file: File, errors: [dynamic]Error) {
	p := Parser {
		src    = src,
		tokens = tokens,
	}

	for peek(&p).kind != .EOF {
		if decl, ok := parse_decl(&p); ok {
			append(&file.decls, decl)
		}
	}
	file.end_pos = peek(&p).end

	errors = p.errors
	return
}

parse_decl :: proc(p: ^Parser) -> (Decl, bool) {
	if p.recovering {
		synchronize(p)
	}

	if peek(p).kind == .Comment {
		return parse_comment_group(p), true
	}

	if peek(p).kind != .Ident {
		t := next(p)
		error_at(p, t.start, fmt.tprintf("expected IDENT, got %s", token.kind_name(t.kind)))
		return {}, false
	}

	err_count := len(p.errors)

	name := expect(p, .Ident)
	params := make([dynamic]Ident)
	defer delete(params)
	for peek(p).kind == .Ident {
		tok := next(p)
		append(&params, Ident{pos = tok.start, name = token.lexeme(tok, p.src)})
	}

	expect(p, .Equal)
	if peek(p).kind == .At {
		decl, ok := parse_binding(p, name)
		if len(p.errors) > err_count {
			destroy_decl(decl)
			return {}, false
		}
		return decl, ok
	}

	decl := parse_rule(p, name, params[:])
	if len(p.errors) > err_count {
		destroy_decl(decl)
		return {}, false
	}
	return decl, true
}

// parse_binding parses `ident "=" "@" "import" "(" string ")" ";"` where the
// "@" token has already been verified to be next.
parse_binding :: proc(p: ^Parser, name: token.Token) -> (Decl, bool) {
	directive := parse_directive(p)

	path: String_Lit
	dir_name, _ := directive.(Directive_Expr)
	if len(dir_name.args) == 1 {
		path, _ = dir_name.args[0].(String_Lit)
	}

	expect(p, .Semicolon)

	return Binding_Decl {
			name = ident_node(name, p.src),
			path = path,
			directive = dir_name,
			pos = name.start,
		},
		true
}

// parse_rule parses `ident "=" production ";"` where the parameter idents have
// already been consumed.
parse_rule :: proc(p: ^Parser, name: token.Token, params: []Ident) -> Decl {
	body := make([dynamic]Expr)
	for peek(p).kind != .Semicolon && peek(p).kind != .EOF {
		prod := parse_production(p)
		append(&body, Term_Expr{x = alloc_expr(prod), pos = expr_pos(prod)})
	}

	if len(body) == 0 {
		error_at(p, name.start, "rule declaration must have a body")
	}

	expect(p, .Semicolon)

	return Rule_Decl {
		name = ident_node(name, p.src),
		params = clone_idents(params),
		body = body,
		pos = name.start,
	}
}

// parse_comment_group consumes consecutive comment tokens into a Comment_Group.
parse_comment_group :: proc(p: ^Parser) -> Decl {
	list := make([dynamic]Comment)
	for peek(p).kind == .Comment {
		t := next(p)
		append(&list, Comment{pos = t.start, text = token.lexeme(t, p.src)})
	}
	return Comment_Group{list = list, pos = list[0].pos}
}

// parse_production parses a production: a sequence or a set of alternatives.
parse_production :: proc(p: ^Parser) -> Expr {
	expr := parse_sequence(p)
	if peek(p).kind == .Pipe {
		alts := make([dynamic]Expr)
		append(&alts, expr)
		for peek(p).kind == .Pipe {
			next(p)
			append(&alts, parse_sequence(p))
		}
		return Alternative_Expr{exprs = alts, pos = expr_pos(expr)}
	}
	return expr
}

// parse_sequence parses `basic { basic }`.
parse_sequence :: proc(p: ^Parser) -> Expr {
	first := parse_basic(p)

	if is_sequence_end(peek(p)) {
		return first
	}

	terms := make([dynamic]Expr)
	append(&terms, first)
	for !is_sequence_end(peek(p)) {
		append(&terms, parse_basic(p))
	}

	if len(terms) == 1 {
		delete(terms)
		return first
	}
	return Sequence_Expr{exprs = terms, pos = expr_pos(first)}
}

is_sequence_end :: proc(t: token.Token) -> bool {
	#partial switch t.kind {
	case .Pipe, .Semicolon, .EOF, .RParen, .RBrack, .RBrace:
		return true
	case:
		return false
	}
}

// parse_basic parses a single basic production element.
parse_basic :: proc(p: ^Parser) -> Expr {
	#partial switch peek(p).kind {
	case .Ident:
		return parse_non_terminal(p)
	case .String, .Regexp:
		return parse_terminal(p)
	case .External:
		t := next(p)

		text := token.lexeme(t, p.src)
		name_end := len(text) - 1

		for i := len(text) - 1; i > 1; i -= 1 {
			ch := text[i]
			if ch != '_' {
				name_end = i + 1
				break
			}
		}

		name := text[2:name_end]
		log.debugf("text %s; name %s", text, name)
		return External_Value{pos = t.start, name = name}
	case .At:
		return parse_directive(p)
	case .Lt:
		return parse_call(p)
	case .LBrack:
		return parse_optional(p)
	case .LBrace:
		return parse_repetition(p)
	case .LParen:
		return parse_group(p)
	case:
		t := next(p)
		error_at(p, t.start, fmt.tprintf("unexpected token %s", token.kind_name(t.kind)))
		return Ident{}
	}
}

// parse_directive parses `"@" ident [ "(" "..." ")" ]`.
parse_directive :: proc(p: ^Parser) -> Expr {
	at := expect(p, .At)
	name := expect(p, .Ident)

	args := make([dynamic]Expr)
	if peek(p).kind == .LParen {
		next(p)
		t := expect(p, .String)
		append(&args, String_Lit{pos = t.start, value = token.lexeme(t, p.src)})
		expect(p, .RParen)
	}

	return Directive_Expr{name = ident_node(name, p.src), args = args, pos = at.start}
}

// parse_terminal parses a string or regexp literal.
parse_terminal :: proc(p: ^Parser) -> Expr {
	t := next(p)
	node := String_Lit {
		pos   = t.start,
		value = token.lexeme(t, p.src),
	}
	if t.kind == .Regexp {
		return Regex_Lit{pos = t.start, value = node.value}
	}
	return node
}

// parse_non_terminal parses an identifier, optionally followed by member
// accesses separated by dots.
parse_non_terminal :: proc(p: ^Parser) -> Expr {
	ident := expect(p, .Ident)
	expr: Expr = ident_node(ident, p.src)

	for peek(p).kind == .Dot {
		next(p)
		sel := expect(p, .Ident)
		expr = Member_Expr {
			object = alloc_expr(expr),
			member = ident_node(sel, p.src),
			pos    = expr_pos(expr),
		}
	}
	return expr
}

// parse_call parses a rule call with arguments, e.g. `<greet person "Mr">`.
parse_call :: proc(p: ^Parser) -> Expr {
	lt := expect(p, .Lt)
	name := parse_non_terminal(p)

	args := make([dynamic]Expr)
	for peek(p).kind != .Gt {
		if peek(p).kind == .EOF {
			error_at(p, lt.start, "unterminated rule call")
			break
		}
		append(&args, parse_basic(p))
	}
	expect(p, .Gt)

	call := new(Call_Expr)
	call.name = name
	call.args = args
	call.pos = lt.start
	return call
}

// parse_optional parses `[ production ]`, e.g. `[ a b ]`.
parse_optional :: proc(p: ^Parser) -> Expr {
	start := expect(p, .LBrack)
	inner := parse_production(p)
	expect(p, .RBrack)
	return Optional_Expr{exprs = unpack_sequence(inner), pos = start.start}
}

// parse_repetition parses `{ production }`, e.g. `{ one two }`.
parse_repetition :: proc(p: ^Parser) -> Expr {
	start := expect(p, .LBrace)
	inner := parse_production(p)
	expect(p, .RBrace)
	return Repetition_Expr{exprs = unpack_sequence(inner), pos = start.start}
}

// parse_group parses `( production )`, e.g. `( a b )`.
parse_group :: proc(p: ^Parser) -> Expr {
	start := expect(p, .LParen)
	inner := parse_production(p)
	expect(p, .RParen)
	return Group_Expr{exprs = unpack_sequence(inner), pos = start.start}
}

// unpack_sequence converts a production into a list of expressions. If the
// production is itself a Sequence_Expr its elements are transferred directly,
// otherwise the production is wrapped in a single-element list.
unpack_sequence :: proc(expr: Expr) -> [dynamic]Expr {
	if seq, ok := expr.(Sequence_Expr); ok {
		return seq.exprs
	}
	list := make([dynamic]Expr)
	append(&list, expr)
	return list
}

peek :: proc(p: ^Parser) -> token.Token {
	if p.pos >= len(p.tokens) do return p.tokens[len(p.tokens) - 1]
	return p.tokens[p.pos]
}

next :: proc(p: ^Parser) -> token.Token {
	if p.pos >= len(p.tokens) do return p.tokens[len(p.tokens) - 1]
	t := p.tokens[p.pos]
	p.pos += 1
	return t
}

expect :: proc(p: ^Parser, kind: token.Kind) -> token.Token {
	t := next(p)
	if t.kind != kind {
		error_at(
			p,
			t.start,
			fmt.tprintf("expected %s, got %s", token.kind_name(kind), token.kind_name(t.kind)),
		)
	}
	return t
}

// synchronize skips tokens until the next plausible declaration start.
synchronize :: proc(p: ^Parser) {
	p.recovering = false
	for peek(p).kind != .EOF {
		if peek(p).kind == .Semicolon {
			next(p)
			return
		}
		#partial switch peek(p).kind {
		case .Ident, .Comment:
			return
		}
		next(p)
	}
}

error_at :: proc(p: ^Parser, offset: int, message: string) {
	if p.recovering do return
	p.recovering = true
	append(&p.errors, Error{offset = offset, message = message})
}

ident_node :: proc(t: token.Token, src: string) -> Ident {
	return Ident{pos = t.start, name = token.lexeme(t, src)}
}

alloc_expr :: proc(expr: Expr, allocator := context.allocator) -> ^Expr {
	p := new(Expr, allocator)
	p^ = expr
	return p
}

clone_idents :: proc(params: []Ident, allocator := context.allocator) -> [dynamic]Ident {
	out := make([dynamic]Ident, 0, len(params), allocator)
	for p in params {
		append(&out, p)
	}
	return out
}
