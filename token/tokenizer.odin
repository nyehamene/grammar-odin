package token

import "core:fmt"

// Error is a lexical diagnostic.
Error :: struct {
	offset:  int,
	message: string,
}

// Tokenizer scans an input source and produces a slice of tokens.
Tokenizer :: struct {
	src:    string,
	offset: int,
}

// scan breaks src into a slice of tokens. Unterminated literals and illegal
// characters produce a corresponding diagnostic in errors. The returned
// slices must be freed with delete.
scan :: proc(
	src: string,
	allocator := context.allocator,
) -> (
	tokens: [dynamic]Token,
	errors: [dynamic]Error,
) {
	tokens = make([dynamic]Token, allocator)
	errors = make([dynamic]Error, allocator)
	t := Tokenizer {
		src = src,
	}

	for t.offset < len(t.src) {
		ch := t.src[t.offset]
		switch {
		case is_space(ch):
			t.offset += 1
		case ch == '/' && peek(t) == '/':
			append(&tokens, scan_comment(&t))
		case ch == '`':
			append(&tokens, scan_tag(&t, &errors))
		case ch == '"':
			append(&tokens, scan_string(&t, &errors))
		case ch == '\'':
			append(&tokens, scan_regexp(&t, &errors))
		case is_ident_start(ch):
			append(&tokens, scan_ident_or_external(&t))
		case ch == '@':
			append(&tokens, single(&t, .At))
		case ch == ';':
			append(&tokens, single(&t, .Semicolon))
		case ch == '=':
			append(&tokens, single(&t, .Equal))
		case ch == '(':
			append(&tokens, single(&t, .LParen))
		case ch == ')':
			append(&tokens, single(&t, .RParen))
		case ch == '[':
			append(&tokens, single(&t, .LBrack))
		case ch == ']':
			append(&tokens, single(&t, .RBrack))
		case ch == '{':
			append(&tokens, single(&t, .LBrace))
		case ch == '}':
			append(&tokens, single(&t, .RBrace))
		case ch == '|':
			append(&tokens, single(&t, .Pipe))
		case ch == '<':
			append(&tokens, single(&t, .Lt))
		case ch == '>':
			append(&tokens, single(&t, .Gt))
		case ch == '.':
			append(&tokens, single(&t, .Dot))
		case:
			append(&tokens, tok(&t, .Illegal, t.offset, t.offset + 1))
			append(
				&errors,
				Error{offset = t.offset, message = fmt.tprintf("illegal character '%c'", ch)},
			)
			t.offset += 1
		}
	}

	append(&tokens, Token{kind = .EOF, start = len(t.src), end = len(t.src)})
	return
}

// peek returns the byte after the current position, or 0 at end of input.
peek :: proc(t: Tokenizer) -> byte {
	if t.offset + 1 < len(t.src) {
		return t.src[t.offset + 1]
	}
	return 0
}

tok :: proc(t: ^Tokenizer, kind: Kind, start, end: int) -> Token {
	return Token{kind = kind, start = start, end = end}
}

single :: proc(t: ^Tokenizer, kind: Kind) -> Token {
	start := t.offset
	t.offset += 1
	return tok(t, kind, start, t.offset)
}

// scan_comment consumes a "//" comment up to, but not including, the newline.
scan_comment :: proc(t: ^Tokenizer) -> Token {
	start := t.offset
	t.offset += 2
	for t.offset < len(t.src) && t.src[t.offset] != '\n' {
		t.offset += 1
	}
	return tok(t, .Comment, start, t.offset)
}

// scan_tag consumes a backtick delimited tag, ex `` `name="value"` ``. The body
// must be a list of `ident "=" string` pairs separated by `;`, which parse_tag
// checks. Like the other literals a tag may not span a line: the formatter
// buckets tokens by the line they start on and relies on none of them crossing a
// newline. A malformed tag is reported and still yields a token so the parser
// keeps its place.
scan_tag :: proc(t: ^Tokenizer, errors: ^[dynamic]Error) -> Token {
	start := t.offset
	t.offset += 1
	body_start := t.offset

	for t.offset < len(t.src) && t.src[t.offset] != '`' {
		if t.src[t.offset] == '\n' {
			append(errors, Error{offset = start, message = "unterminated tag literal"})
			return tok(t, .Tag, start, t.offset)
		}
		t.offset += 1
	}
	if t.offset >= len(t.src) {
		append(errors, Error{offset = start, message = "unterminated tag literal"})
		return tok(t, .Tag, start, t.offset)
	}
	body := t.src[body_start:t.offset]
	t.offset += 1

	pairs, ok := parse_tag(body)
	defer delete(pairs)
	if !ok {
		append(errors, Error{offset = start, message = "invalid tag literal"})
	}
	return tok(t, .Tag, start, t.offset)
}

// scan_string consumes a double-quoted string literal.
scan_string :: proc(t: ^Tokenizer, errors: ^[dynamic]Error) -> Token {
	start := t.offset
	t.offset += 1
	for t.offset < len(t.src) {
		ch := t.src[t.offset]
		if ch == '\\' {
			next_offset := t.offset + 1
			if next_offset < len(t.src) {
				next := t.src[next_offset]
				switch next {
				case '"', '\\':
					// skip
					t.offset = next_offset + 1
					continue
				}
			}
		}
		if ch == '"' {
			t.offset += 1
			return tok(t, .String, start, t.offset)
		}
		if ch == '\n' {
			append(errors, Error{offset = start, message = "unterminated string literal"})
			return tok(t, .String, start, t.offset)
		}
		t.offset += 1
	}
	append(errors, Error{offset = start, message = "unterminated string literal"})
	return tok(t, .String, start, t.offset)
}

// scan_regexp consumes a single-quoted regexp literal.
scan_regexp :: proc(t: ^Tokenizer, errors: ^[dynamic]Error) -> Token {
	start := t.offset
	t.offset += 1
	for t.offset < len(t.src) {
		ch := t.src[t.offset]
		if ch == '\\' {
			next_offset := t.offset + 1
			if next_offset < len(t.src) {
				next := t.src[next_offset]
				switch next {
				case '\'', '\\':
					// skip
					t.offset = next_offset + 1
					continue
				}
			}
		}
		if ch == '\'' {
			t.offset += 1
			return tok(t, .Regexp, start, t.offset)
		}
		if ch == '\n' {
			// A literal may not span a line: the formatter buckets tokens by the
			// line they start on and relies on none of them crossing a newline.
			append(errors, Error{offset = start, message = "unterminated regexp literal"})
			return tok(t, .Regexp, start, t.offset)
		}
		t.offset += 1
	}
	append(errors, Error{offset = start, message = "unterminated regexp literal"})
	return tok(t, .Regexp, start, t.offset)
}

// scan_ident_or_external scans an identifier, preferring the "__name"
// external identifier form when it matches.
scan_ident_or_external :: proc(t: ^Tokenizer) -> Token {
	start := t.offset

	if t.src[t.offset] == '_' && t.offset + 1 < len(t.src) && t.src[t.offset + 1] == '_' {
		if ext, ok := try_external(t); ok {
			return ext
		}
	}

	for t.offset < len(t.src) && is_ident_part(t.src[t.offset]) {
		t.offset += 1
	}
	return tok(t, .Ident, start, t.offset)
}

// try_external attempts to scan an external identifier, which is a "__" prefix
// followed by a letter or underscore and then any run of alphanumerics and
// underscores: `__[a-zA-Z_][a-zA-Z0-9_]*`. There is no closing delimiter, so the
// external runs to the end of the identifier and its name is everything after
// the prefix. On failure the tokenizer position is left unchanged.
try_external :: proc(t: ^Tokenizer) -> (Token, bool) {
	start := t.offset
	cursor := t.offset + 2

	if cursor >= len(t.src) || !is_external_start(t.src[cursor]) {
		return Token{}, false
	}

	// The first character is already validated as a letter or underscore, which
	// is also an identifier body character, so the run starts here.
	for cursor < len(t.src) && is_ident_part(t.src[cursor]) {
		cursor += 1
	}

	t.offset = cursor
	return tok(t, .External, start, t.offset), true
}

is_space :: proc(ch: byte) -> bool {
	return ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n'
}

is_alpha :: proc(ch: byte) -> bool {
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
}

is_ident_start :: proc(ch: byte) -> bool {
	return is_alpha(ch) || ch == '_'
}

is_ident_part :: proc(ch: byte) -> bool {
	return is_alpha(ch) || ch == '_' || (ch >= '0' && ch <= '9')
}

is_external_start :: proc(ch: byte) -> bool {
	return is_alpha(ch) || ch == '_'
}
