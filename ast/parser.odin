package ast

import "base:runtime"
import "core:fmt"
import "core:log"

import "../token"

// Parser is a recursive descent parser over a tokenized grammar source.
Parser :: struct {
	allocator:     runtime.Allocator,
	src:           string,
	tokens:        []token.Token,
	pos:           int,
	errors:        [dynamic]Error,
	recovering:    bool,
	skip_comments: bool,
}

// parse_file parses the tokenized source into a File. Syntax diagnostics are
// appended to errors. If errors is non-empty the returned File may be partial.
parse_file :: proc(
	src: string,
	tokens: []token.Token,
	allocator := context.allocator,
) -> (
	File,
	[dynamic]Error,
) {

	file: File
	file.decls = make([dynamic]Decl, allocator)
	errors := make([dynamic]Error, allocator)

	p := Parser {
		allocator = allocator,
		src       = src,
		tokens    = tokens,
	}

	for peek(&p).kind != .EOF {
		if decl, ok := parse_decl(&p); ok {
			append(&file.decls, decl)
		}
	}

	file.end_pos = peek(&p).end
	errors = p.errors
	return file, errors
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

	// From here to the end of the declaration a comment is trivia: it may sit
	// between the parameters, inside the body, or between any two tokens of it.
	// The flag is restored on the way out so the next declaration can still see
	// a comment that introduces it.
	outer_skip := p.skip_comments
	p.skip_comments = true
	defer p.skip_comments = outer_skip

	params := make([dynamic]Ident, p.allocator)
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
	dir_name, _ := directive.(Directive)
	if len(dir_name.args) == 1 {
		path, _ = dir_name.args[0].(String_Lit)
	}

	expect(p, .Semicolon)

	return Binding {
			ident = ident_node(name, p.src),
			path = path,
			directive = dir_name,
			pos = name.start,
		},
		true
}

// parse_rule parses `ident "=" production ";"` where the parameter idents have
// already been consumed. A rule names one production: a body of more than one
// element is a sequence, which parse_production has already built by the time it
// returns.
parse_rule :: proc(p: ^Parser, name: token.Token, params: []Ident) -> Decl {
	if peek(p).kind == .Semicolon || peek(p).kind == .EOF {
		error_at(p, name.start, "rule declaration must have a body")
		expect(p, .Semicolon)
		return Rule {
			ident = ident_node(name, p.src),
			params = clone_idents(params, p.allocator),
			pos = name.start,
		}
	}

	production := parse_production(p)

	expect(p, .Semicolon)

	return Rule {
		ident = ident_node(name, p.src),
		params = clone_idents(params, p.allocator),
		production = production,
		pos = name.start,
	}
}

// parse_comment_group consumes consecutive comment tokens into a Comment_Group.
parse_comment_group :: proc(p: ^Parser) -> Decl {
	list := make([dynamic]Comment, p.allocator)
	for peek(p).kind == .Comment {
		t := next(p)
		append(&list, Comment{pos = t.start, text = token.lexeme(t, p.src)})
	}
	return Comment_Group{list = list, pos = list[0].pos}
}

// parse_production parses a production: a sequence or a set of alternatives.
parse_production :: proc(p: ^Parser) -> Production {
	lhs := parse_sequence(p)
	if peek(p).kind != .Pipe do return lhs

	// Each branch folds into the left of the one before it, so `a | b | c` is
	// `( a | b ) | c`. pos is that of the first branch, which is what a single
	// alternative over the same branches reported before it became a chain.
	pos := production_pos(lhs)
	for peek(p).kind == .Pipe {
		next(p)
		lhs = Alternative {
			lhs = alloc_production(lhs, p.allocator),
			rhs = alloc_production(parse_sequence(p), p.allocator),
			pos = pos,
		}
	}
	return lhs
}

// parse_sequence parses `basic { basic } [ tag ]`. A tag annotates the production
// it follows rather than standing on its own, so it wraps the whole sequence: in
// `a b c `name="value"`` the annotated production is `a b c`, not `c` alone. A
// sequence that carries on after a tag rejects it, since a tag must be the last
// element of its production or alternative, and a production carries one tag at
// most.
parse_sequence :: proc(p: ^Parser) -> Production {
	// A tag annotates what came before it, so a production may not start with
	// one: `foo = `name="value"`;` would name no production at all.
	if peek(p).kind == .Tag {
		t := next(p)
		delete(parse_tag_pairs(p, t))
		error_at(p, t.start, "a tag must annotate a production element")
		return Ident{}
	}

	first := parse_basic(p)

	if is_sequence_end(peek(p)) {
		return first
	}

	terms := make([dynamic]Production, p.allocator)
	append(&terms, first)
	tag_seen := false
	for !is_sequence_end(peek(p)) {
		if peek(p).kind == .Tag {
			t := next(p)
			pairs := parse_tag_pairs(p, t)
			if tag_seen {
				// The production is already annotated, so a second tag has
				// nothing left to annotate. Drop it and keep the first one.
				delete(pairs)
				error_at(p, t.start, "a production may carry only one tag")
				continue
			}
			tag_seen = true
			// Everything parsed so far becomes the annotated production, so a tag
			// over `a b c` wraps the sequence and not just its last element.
			annotated := sequence_or_single(terms)
			terms = make([dynamic]Production, p.allocator)
			append(
				&terms,
				Tagged_Production {
					production = alloc_production(annotated),
					tag = pairs,
					pos = production_pos(annotated),
				},
			)
			// A further tag is reported on its own above, so only an element
			// here is the tag standing in the wrong place.
			if peek(p).kind != .Tag && !is_sequence_end(peek(p)) {
				error_at(p, t.start, "a tag must be the last element in a production")
			}
			continue
		}
		append(&terms, parse_basic(p))
	}

	return sequence_or_single(terms)
}

// sequence_or_single turns the elements collected for a sequence into the
// production they describe: a single element stands alone, several make a
// Sequence. The list is handed over to the result rather than copied, and
// freed when there is nothing to keep.
sequence_or_single :: proc(terms: [dynamic]Production) -> Production {
	if len(terms) == 1 {
		only := terms[0]
		delete(terms)
		return only
	}
	return Sequence{productions = terms, pos = production_pos(terms[0])}
}

// parse_tag_pairs splits the scanned tag into its pairs, one per `name="value"`
// entry. The tokenizer has already reported a malformed tag, so a body it
// rejected yields no pairs here rather than a second diagnostic for the same
// offset. The returned list is owned by the caller.
parse_tag_pairs :: proc(p: ^Parser, t: token.Token) -> [dynamic]Tag_Pair {
	lex := token.lexeme(t, p.src)
	// Strip the backticks: the first opens the tag and the last closes it.
	scanned, ok := token.parse_tag(lex[1:len(lex) - 1])
	defer delete(scanned)

	pairs := make([dynamic]Tag_Pair, 0, len(scanned), p.allocator)
	if !ok {
		return pairs
	}
	for pair in scanned {
		// The opening backtick sits between the token start and the body.
		pos := t.start + 1 + pair.pos
		append(
			&pairs,
			Tag_Pair {
				ident = Ident{pos = pos, name = pair.name},
				value = String_Lit{pos = pos, value = pair.value},
				pos = pos,
			},
		)
	}
	return pairs
}

// trailing_tag_pos returns the offset of the tag that closes production when production is a
// production annotated by one, and reports false otherwise. It descends into a
// sequence or an alternative so it finds the tag of a nested production, which is
// how a tag written inside a group, a repetition or an optional is found.
trailing_tag_pos :: proc(production: Production) -> (int, bool) {
	#partial switch v in production {
	case Tagged_Production:
		if len(v.tag) > 0 do return v.tag[0].pos, true
	case Sequence:
		if len(v.productions) > 0 {
			return trailing_tag_pos(v.productions[len(v.productions) - 1])
		}
	case Alternative:
		// The chain leans left, so its last branch is the one the right
		// spine reaches.
		return trailing_tag_pos(v.rhs^)
	case Group:
		return trailing_tag_pos(v.production^)
	case Optional:
		return trailing_tag_pos(v.production^)
	case Repetition:
		return trailing_tag_pos(v.production^)
	}
	return 0, false
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
parse_basic :: proc(p: ^Parser) -> Production {
	#partial switch peek(p).kind {
	case .Ident:
		switch it in parse_non_terminal(p) {
		case Ident:
			return it
		case Qual_Ident:
			return it
		}
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
	case .Tag:
		// parse_sequence consumes a tag and attaches it to the element before it,
		// so reaching one here means it annotates nothing.
		t := next(p)
		delete(parse_tag_pairs(p, t))
		error_at(p, t.start, "a tag must annotate a production element")
		return Ident{}
	}

	t := next(p)
	error_at(p, t.start, fmt.tprintf("unexpected token %s", token.kind_name(t.kind)))
	return Ident{}
}

// parse_directive parses `"@" ident [ "(" "..." ")" ]`.
parse_directive :: proc(p: ^Parser) -> Production {
	at := expect(p, .At)
	name := expect(p, .Ident)

	args := make([dynamic]Production, p.allocator)
	if peek(p).kind == .LParen {
		next(p)
		t := expect(p, .String)
		append(&args, String_Lit{pos = t.start, value = token.lexeme(t, p.src)})
		expect(p, .RParen)
	}

	return Directive{ident = ident_node(name, p.src), args = args, pos = at.start}
}

// parse_terminal parses a string or regexp literal.
parse_terminal :: proc(p: ^Parser) -> Production {
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
parse_non_terminal :: proc(p: ^Parser) -> Any_Ident {
	ident := expect(p, .Ident)
	lhs := ident_node(ident, p.src)

	if peek(p).kind == .Dot {
		next(p)
		sel := expect(p, .Ident)
		production := Qual_Ident {
			lhs = lhs,
			rhs = ident_node(sel, p.src),
			pos = production_pos(lhs),
		}
		return production
	}
	return lhs
}

// parse_call parses a rule call with arguments, e.g. `<greet person "Mr">`.
parse_call :: proc(p: ^Parser) -> Production {
	lt := expect(p, .Lt)
	name := parse_non_terminal(p)

	args := make([dynamic]Production, p.allocator)
	for peek(p).kind != .Gt {
		if peek(p).kind == .EOF {
			error_at(p, lt.start, "unterminated rule call")
			break
		}
		if peek(p).kind == .Tag {
			t := next(p)
			delete(parse_tag_pairs(p, t))
			error_at(
				p,
				t.start,
				"a tag may not appear inside a group, repetition, optional or call",
			)
			continue
		}
		append(&args, parse_basic(p))
	}
	expect(p, .Gt)

	call := new(Call, p.allocator)
	call.ident = name
	call.args = args
	call.pos = lt.start
	return call
}

// parse_optional parses `[ production ]`, e.g. `[ a b ]`.
parse_optional :: proc(p: ^Parser) -> Production {
	start := expect(p, .LBrack)
	inner := parse_production(p)
	reject_inner_tag(p, inner)
	expect(p, .RBrack)
	return Optional{production = alloc_production(inner, p.allocator), pos = start.start}
}

// parse_repetition parses `{ production }`, e.g. `{ one two }`.
parse_repetition :: proc(p: ^Parser) -> Production {
	start := expect(p, .LBrace)
	inner := parse_production(p)
	reject_inner_tag(p, inner)
	expect(p, .RBrace)
	return Repetition{production = alloc_production(inner, p.allocator), pos = start.start}
}

// parse_group parses `( production )`, e.g. `( a b )`.
parse_group :: proc(p: ^Parser) -> Production {
	start := expect(p, .LParen)
	inner := parse_production(p)
	reject_inner_tag(p, inner)
	expect(p, .RParen)
	return Group{production = alloc_production(inner, p.allocator), pos = start.start}
}

// reject_inner_tag reports a tag found at the end of a production nested inside
// a grouping symbol or a call. A tag annotates the last element of a production
// or an alternative, and an element inside one of these is neither, so
// `( a x `name="value"` )` must be written `( a x ) `name="value"``.
reject_inner_tag :: proc(p: ^Parser, inner: Production) {
	if pos, tagged := trailing_tag_pos(inner); tagged {
		error_at(p, pos, "a tag may not appear inside a group, repetition, optional or call")
	}
}


// skip_trivia advances past the comment tokens that stand in for whitespace.
// Comments are trivia only inside a declaration: at the top level a comment is a
// declaration of its own, so the skip stays off until parse_decl has consumed a
// name.
skip_trivia :: proc(p: ^Parser) {
	if !p.skip_comments do return
	for p.pos < len(p.tokens) && p.tokens[p.pos].kind == .Comment {
		p.pos += 1
	}
}

peek :: proc(p: ^Parser) -> token.Token {
	skip_trivia(p)
	if p.pos >= len(p.tokens) do return p.tokens[len(p.tokens) - 1]
	return p.tokens[p.pos]
}

next :: proc(p: ^Parser) -> token.Token {
	skip_trivia(p)
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

alloc_production :: proc(production: Production, allocator := context.allocator) -> ^Production {
	p := new(Production, allocator)
	p^ = production
	return p
}

clone_idents :: proc(params: []Ident, allocator := context.allocator) -> [dynamic]Ident {
	out := make([dynamic]Ident, 0, len(params), allocator)
	for p in params {
		append(&out, p)
	}
	return out
}
