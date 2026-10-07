package ast

// Production is any production that can appear in a grammar.
Production :: union {
	Ident,
	String_Lit,
	Regex_Lit,
	External_Value,
	Sequence,
	Alternative,
	Optional,
	Repetition,
	Group,
	Qual_Ident,
	Directive,
	Tagged_Production,
	^Call,
}

// Decl is any top-level declaration in a grammar file.
Decl :: union {
	Rule,
	Binding,
	Comment_Group,
}

// File is the root node of a parsed grammar source.
File :: struct {
	decls:   [dynamic]Decl,
	end_pos: int,
}

// Rule is a named production, optionally with parameters. A rule names one
// production, so a body of more than one element is a Sequence.
//   greeting            = "Hello";
//   greet name title    = "hello" name title;
Rule :: struct {
	ident:      Ident,
	params:     [dynamic]Ident,
	production: Production,
	pos:        int,
}

// Binding imports an external grammar file.
//   f = @import("../foo");
Binding :: struct {
	ident:     Ident,
	path:      String_Lit,
	directive: Directive,
	pos:       int,
}

// Comment_Group is a run of consecutive comments.
Comment_Group :: struct {
	list: [dynamic]Comment,
	pos:  int,
}

Comment :: struct {
	pos:  int,
	text: string,
}

// Ident is an identifier.
Ident :: struct {
	pos:  int,
	name: string,
}

// String_Lit is a string literal, including its surrounding quotes in value.
String_Lit :: struct {
	pos:   int,
	value: string,
}

// Regex_Lit is a regexp literal, including its surrounding quotes in value.
Regex_Lit :: struct {
	pos:   int,
	value: string,
}

// External_Value references an external value, e.g. __name__.
External_Value :: struct {
	pos:  int,
	name: string,
}

// Sequence is a sequence of productions, e.g. `a b c`.
Sequence :: struct {
	productions: [dynamic]Production,
	pos:         int,
}

// Alternative is a choice between two productions, e.g. `a | b`. A run of them
// is a chain leaning left, so `a | b | c` is `( a | b ) | c`, and a branch in
// parentheses is a Group rather than part of the chain.
Alternative :: struct {
	lhs: ^Production,
	rhs: ^Production,
	pos:  int,
}

// Optional is a zero-or-one production, e.g. `[ a b ]`.
Optional :: struct {
	production: ^Production,
	pos:        int,
}

// Repetition is a zero-or-more production, e.g. `{ one two }`.
Repetition :: struct {
	production: ^Production,
	pos:        int,
}

// Group is a grouped production, e.g. `( a b )`.
Group :: struct {
	production: ^Production,
	pos:        int,
}

// Qual_Ident is a member access, e.g. `foo.bar`. It is left-associative, so
// `a.b` is Qual_Ident{a, b}.
Qual_Ident :: struct {
	lhs: Ident,
	rhs: Ident,
	pos: int,
}

Any_Ident :: union {
	Ident,
	Qual_Ident,
}

// Call is a call to a rule with arguments, e.g. `<greet person "Mr">`.
Call :: struct {
	// name: Production,
	ident: Any_Ident,
	args:  [dynamic]Production,
	pos:   int,
}

// Directive is a directive, e.g. `@import("base")`.
Directive :: struct {
	ident: Ident,
	args:  [dynamic]Production,
	pos:   int,
}

// Tagged_Production is a production annotated with one or more tags, e.g.
// `a b `name="value"``. pos is the offset of the annotated production, so the
// production reports the position of the element it wraps rather than that of
// the tag written after it.
Tagged_Production :: struct {
	production: ^Production,
	tag:        [dynamic]Tag_Pair,
	pos:        int,
}

// Tag_Pair is one `name="value"` entry of a tag. value keeps its quotes, like
// String_Lit.
Tag_Pair :: struct {
	ident: Ident,
	value: String_Lit,
	pos:   int,
}

// Error is a syntax diagnostic produced by the parser.
Error :: struct {
	offset:  int,
	message: string,
}

// production_pos returns the source offset of the first token of production.
production_pos :: proc(production: Production) -> int {
	switch v in production {
	case Ident:
		return v.pos
	case String_Lit:
		return v.pos
	case Regex_Lit:
		return v.pos
	case External_Value:
		return v.pos
	case Sequence:
		return v.pos
	case Alternative:
		return v.pos
	case Optional:
		return v.pos
	case Repetition:
		return v.pos
	case Group:
		return v.pos
	case Qual_Ident:
		return v.pos
	case ^Call:
		return v.pos
	case Directive:
		return v.pos
	case Tagged_Production:
		return v.pos
	}
	return 0
}

// decl_pos returns the source offset of the first token of decl.
decl_pos :: proc(decl: Decl) -> int {
	switch v in decl {
	case Rule:
		return v.pos
	case Binding:
		return v.pos
	case Comment_Group:
		return v.pos
	}
	return 0
}

// destroy_file frees all allocations owned by file.
destroy_file :: proc(file: ^File) {
	for decl in file.decls {
		destroy_decl(decl)
	}
	delete(file.decls)
}

destroy_decl :: proc(decl: Decl) {
	switch v in decl {
	case Rule:
		delete(v.params)
		if v.production != nil do destroy_production(v.production)
	case Binding:
		destroy_production(v.directive)
	case Comment_Group:
		delete(v.list)
	}
}

// collect_branches returns the branches of an alternative as a flat list. The chain
// of choices leans left, so the branches are read by walking the left spine down and
// taking the right side at each step. Each branch is handed over to the caller, and
// the chain holds nothing of its own to free. The list belongs to the caller.
collect_branches :: proc(alternative: Alternative) -> [dynamic]Production {
	branches := make([dynamic]Production)
	collect_branches_into(alternative, &branches)
	return branches
}

collect_branches_into :: proc(alternative: Alternative, branches: ^[dynamic]Production) {
	inner, is_chain := alternative.lhs^.(Alternative)
	if is_chain {
		collect_branches_into(inner, branches)
	} else {
		append(branches, alternative.lhs^)
	}
	append(branches, alternative.rhs^)
}

destroy_production :: proc(production: Production) {
	switch v in production {
	case Ident, String_Lit, Regex_Lit, External_Value:
	case Sequence:
		for e in v.productions {
			destroy_production(e)
		}
		delete(v.productions)
	case Alternative:
		destroy_production(v.lhs^)
		free(v.lhs)
		destroy_production(v.rhs^)
		free(v.rhs)
	case Optional:
		destroy_production(v.production^)
		free(v.production)
	case Repetition:
		destroy_production(v.production^)
		free(v.production)
	case Group:
		destroy_production(v.production^)
		free(v.production)
	case Qual_Ident:
	case ^Call:
		for e in v.args {
			destroy_production(e)
		}
		delete(v.args)
		free(v)
	case Directive:
		for e in v.args {
			destroy_production(e)
		}
		delete(v.args)
	case Tagged_Production:
		destroy_production(v.production^)
		free(v.production)
		delete(v.tag)
	}
}

// Decl_Index_At returns the index of the declaration that covers offset, and ok is
// false when the offset falls outside every declaration, which is past the end of
// the file or inside the run of whitespace between two of them.
//
// Declarations are in source order and none spans another, so the one that covers
// an offset is the last one that starts at or before it. A position in a blank line
// between two declarations therefore belongs to the one before it.
Decl_Index_At :: proc(file: ^File, offset: int) -> (index: int, ok: bool) {
	found := -1
	for d, i in file.decls {
		if decl_pos(d) > offset do break
		found = i
	}
	return found, found >= 0
}
