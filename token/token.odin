package token

// Kind enumerates the token kinds produced by the tokenizer.
Kind :: enum {
	Illegal,
	EOF,
	Ident,
	String,
	Regexp,
	External,
	Comment,
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
