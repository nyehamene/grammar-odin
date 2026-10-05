package token

import "core:io"
import "core:strconv"
import "core:strings"

// Kind enumerates the token kinds produced by the tokenizer.
Kind :: enum {
	Illegal,
	EOF,
	Ident,
	String,
	Regexp,
	External,
	Comment,
	Tag,
	At,
	LParen,
	RParen,
	LBrack,
	RBrack,
	LBrace,
	RBrace,
	Pipe,
	Dot,
	Equal,
	Lt,
	Gt,
	Semicolon,
}

// kind_name returns the display name of a token kind.
kind_name :: proc(kind: Kind) -> string {
	switch kind {
	case .Illegal:
		return "Illegal"
	case .EOF:
		return "EOF"
	case .Ident:
		return "Ident"
	case .String:
		return "String"
	case .Regexp:
		return "Regexp"
	case .External:
		return "External"
	case .Comment:
		return "Comment"
	case .Tag:
		return "Tag"
	case .At:
		return "At"
	case .LParen:
		return "LParen"
	case .RParen:
		return "RParen"
	case .LBrack:
		return "LBrack"
	case .RBrack:
		return "RBrack"
	case .LBrace:
		return "LBrace"
	case .RBrace:
		return "RBrace"
	case .Pipe:
		return "Pipe"
	case .Dot:
		return "Dot"
	case .Equal:
		return "Equal"
	case .Lt:
		return "Lt"
	case .Gt:
		return "Gt"
	case .Semicolon:
		return "Semicolon"
	}
	return "Unknown"
}

// Token is a single lexical token in the source.
Token :: struct {
	kind:  Kind,
	start: int, // byte offset of the start of the lexeme
	end:   int, // byte offset one past the end of the lexeme
}

// lexeme returns the source text spanned by the token.
lexeme :: proc(tok: Token, src: string) -> string {
	low := max(tok.start, 0)
	high := min(tok.end, len(src))
	if high < low do return ""
	return src[low:high]
}

// write_lexeme writes lex to writer, escaping whitespace characters so the
// lexeme stays on a single line.
write_lexeme :: proc(writer: io.Writer, lex: string) {
	if !strings.contains_any(lex, "\n\r\t") {
		io.write_string(writer, lex)
		return
	}
	for ch in lex {
		switch ch {
		case '\n':
			io.write_string(writer, "\\n")
		case '\r':
			io.write_string(writer, "\\r")
		case '\t':
			io.write_string(writer, "\\t")
		case:
			buf := [1]u8{u8(ch)}
			io.write_string(writer, string(buf[:]))
		}
	}
}

Position :: struct {
	line:   int,
	column: int,
}

// position_at returns the 1-based line and column of offset in src.
position_at :: proc(src: string, offset_arg: int) -> Position {
	offset := offset_arg
	line := 1
	column := 1
	if offset > len(src) do offset = len(src)
	for i in 0 ..< offset {
		if src[i] == '\n' {
			line += 1
			column = 1
		} else {
			column += 1
		}
	}
	return Position{line = line, column = column}
}

// Parse_Position reads a position written as `line:column`, and ok is false when the
// text is not that shape or a part is not a positive number. It is the text form of
// Position, which offset_at takes.
Parse_Position :: proc(text: string) -> (pos: Position, ok: bool) {
	colon := strings.index(text, ":")
	if colon < 1 || colon == len(text) - 1 do return Position{}, false

	line, line_ok := strconv.parse_int(text[:colon])
	column, column_ok := strconv.parse_int(text[colon + 1:])
	if !line_ok || !column_ok do return Position{}, false
	if line < 1 || column < 1 do return Position{}, false

	return Position{line = line, column = column}, true
}

// offset_at returns the byte offset of pos in src. ok is false when src has no such
// line or the column falls past the end of it. It is the inverse of position_at,
// which counts a line break as the end of the line before it.
offset_at :: proc(src: string, pos: Position) -> (offset: int, ok: bool) {
	if pos.line < 1 || pos.column < 1 do return 0, false

	line := 1
	i := 0
	for i < len(src) && line < pos.line {
		if src[i] == '\n' do line += 1
		i += 1
	}
	if line != pos.line do return 0, false

	at := i + pos.column - 1
	if at > len(src) do return 0, false
	return at, true
}

// Selection is a position together with the file it was written against. file is
// empty when the text named no file, in which case the selection applies to every
// file loaded.
Selection :: struct {
	file: string,
	pos:  Position,
}

// Parse_Selection reads a selection written as `line:column` or as
// `file:line:column`. ok is false when the text is neither shape, or when a part is
// not a positive number.
//
// The file is taken as everything before the last two colons, so a path that holds
// a colon does not confuse it. An empty file part, as in `:3:1`, is the same as
// writing none at all.
Parse_Selection :: proc(text: string) -> (sel: Selection, ok: bool) {
	column_at := strings.last_index(text, ":")
	if column_at < 0 do return Selection{}, false

	line_at := strings.last_index(text[:column_at], ":")
	if line_at < 0 {
		// Only one colon, so the text is a bare position.
		pos, pos_ok := Parse_Position(text)
		return Selection{pos = pos}, pos_ok
	}

	pos, pos_ok := Parse_Position(text[line_at+1:])
	if !pos_ok do return Selection{}, false

	file := text[:line_at]
	if len(file) == 0 do return Selection{pos = pos}, true
	return Selection{file = file, pos = pos}, true
}
