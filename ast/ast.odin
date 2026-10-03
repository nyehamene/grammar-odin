package ast

// Expr is any expression that can appear in a production.
Expr :: union {
	Ident,
	String_Lit,
	Regex_Lit,
	External_Value,
	Term_Expr,
	Sequence_Expr,
	Alternative_Expr,
	Optional_Expr,
	Repetition_Expr,
	Group_Expr,
	Member_Expr,
	^Call_Expr,
	Directive_Expr,
	Tagged_Expr,
}

// Decl is any top-level declaration in a grammar file.
Decl :: union {
	Rule_Decl,
	Binding_Decl,
	Comment_Group,
}

// File is the root node of a parsed grammar source.
File :: struct {
	decls:   [dynamic]Decl,
	end_pos: int,
}

// Rule_Decl is a named production, optionally with parameters.
//   greeting            = "Hello";
//   greet name title    = "hello" name title;
Rule_Decl :: struct {
	name:   Ident,
	params: [dynamic]Ident,
	body:   [dynamic]Expr,
	pos:    int,
}

// Binding_Decl imports an external grammar file.
//   f = @import("../foo");
Binding_Decl :: struct {
	name:      Ident,
	path:      String_Lit,
	directive: Directive_Expr,
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

// Term_Expr represents a single production appearing in a rule body.
Term_Expr :: struct {
	x:   ^Expr,
	pos: int,
}

// Sequence_Expr is a sequence of basics, e.g. `a b c`.
Sequence_Expr :: struct {
	exprs: [dynamic]Expr,
	pos:   int,
}

// Alternative_Expr is a set of alternatives, e.g. `a | b | c`.
Alternative_Expr :: struct {
	exprs: [dynamic]Expr,
	pos:   int,
}

// Optional_Expr is a zero-or-one production, e.g. `[ a b ]`.
Optional_Expr :: struct {
	exprs: [dynamic]Expr,
	pos:   int,
}

// Repetition_Expr is a zero-or-more production, e.g. `{ one two }`.
Repetition_Expr :: struct {
	exprs: [dynamic]Expr,
	pos:   int,
}

// Group_Expr is a grouped production, e.g. `( a b )`.
Group_Expr :: struct {
	exprs: [dynamic]Expr,
	pos:   int,
}

// Member_Expr is a member access, e.g. `foo.bar`. It is left-associative, so
// `a.b.c` is Member_Expr{Member_Expr{a, b}, c}.
Member_Expr :: struct {
	object: ^Expr,
	member: Ident,
	pos:    int,
}

// Call_Expr is a call to a rule with arguments, e.g. `<greet person "Mr">`.
Call_Expr :: struct {
	name: Expr,
	args: [dynamic]Expr,
	pos:  int,
}

// Directive_Expr is a directive, e.g. `@import("base")`.
Directive_Expr :: struct {
	name: Ident,
	args: [dynamic]Expr,
	pos:  int,
}

// Tagged_Expr is a production annotated with one or more tags, e.g.
// `a b `name="value"``. pos is the offset of the annotated production, so the
// expression reports the position of the element it wraps rather than that of
// the tag written after it.
Tagged_Expr :: struct {
	expr: ^Expr,
	tag:  [dynamic]Tag_Pair,
	pos:  int,
}

// Tag_Pair is one `name="value"` entry of a tag. value keeps its quotes, like
// String_Lit.
Tag_Pair :: struct {
	name:  Ident,
	value: String_Lit,
	pos:   int,
}

// Error is a syntax diagnostic produced by the parser.
Error :: struct {
	offset:  int,
	message: string,
}

// expr_pos returns the source offset of the first token of expr.
expr_pos :: proc(expr: Expr) -> int {
	switch v in expr {
	case Ident:
		return v.pos
	case String_Lit:
		return v.pos
	case Regex_Lit:
		return v.pos
	case External_Value:
		return v.pos
	case Term_Expr:
		return v.pos
	case Sequence_Expr:
		return v.pos
	case Alternative_Expr:
		return v.pos
	case Optional_Expr:
		return v.pos
	case Repetition_Expr:
		return v.pos
	case Group_Expr:
		return v.pos
	case Member_Expr:
		return v.pos
	case ^Call_Expr:
		return v.pos
	case Directive_Expr:
		return v.pos
	case Tagged_Expr:
		return v.pos
	}
	return 0
}

// decl_pos returns the source offset of the first token of decl.
decl_pos :: proc(decl: Decl) -> int {
	switch v in decl {
	case Rule_Decl:
		return v.pos
	case Binding_Decl:
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
	case Rule_Decl:
		delete(v.params)
		for body in v.body {
			destroy_expr(body)
		}
		delete(v.body)
	case Binding_Decl:
		destroy_expr(v.directive)
	case Comment_Group:
		delete(v.list)
	}
}

destroy_expr :: proc(expr: Expr) {
	switch v in expr {
	case Ident, String_Lit, Regex_Lit, External_Value:
	case Term_Expr:
		destroy_expr(v.x^)
		free(v.x)
	case Sequence_Expr:
		for e in v.exprs {
			destroy_expr(e)
		}
		delete(v.exprs)
	case Alternative_Expr:
		for e in v.exprs {
			destroy_expr(e)
		}
		delete(v.exprs)
	case Optional_Expr:
		for e in v.exprs {
			destroy_expr(e)
		}
		delete(v.exprs)
	case Repetition_Expr:
		for e in v.exprs {
			destroy_expr(e)
		}
		delete(v.exprs)
	case Group_Expr:
		for e in v.exprs {
			destroy_expr(e)
		}
		delete(v.exprs)
	case Member_Expr:
		destroy_expr(v.object^)
		free(v.object)
	case ^Call_Expr:
		for e in v.args {
			destroy_expr(e)
		}
		delete(v.args)
		free(v)
	case Directive_Expr:
		for e in v.args {
			destroy_expr(e)
		}
		delete(v.args)
	case Tagged_Expr:
		destroy_expr(v.expr^)
		free(v.expr)
		delete(v.tag)
	}
}
