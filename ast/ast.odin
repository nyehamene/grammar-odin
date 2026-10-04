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
	Group_Expr,
	Member_Access,
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
	name:   Ident,
	params: [dynamic]Ident,
	expr:   Production,
	pos:    int,
}

// Binding imports an external grammar file.
//   f = @import("../foo");
Binding :: struct {
	name:      Ident,
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
	exprs: [dynamic]Production,
	pos:   int,
}

// Alternative is a set of alternatives, e.g. `a | b | c`.
Alternative :: struct {
	exprs: [dynamic]Production,
	pos:   int,
}

// Optional is a zero-or-one production, e.g. `[ a b ]`.
Optional :: struct {
	exprs: [dynamic]Production,
	pos:   int,
}

// Repetition is a zero-or-more production, e.g. `{ one two }`.
Repetition :: struct {
	exprs: [dynamic]Production,
	pos:   int,
}

// Group_Expr is a grouped production, e.g. `( a b )`.
Group_Expr :: struct {
	exprs: [dynamic]Production,
	pos:   int,
}

// Member_Access is a member access, e.g. `foo.bar`. It is left-associative, so
// `a.b.c` is Member_Access{Member_Access{a, b}, c}.
Member_Access :: struct {
	object: ^Production,
	member: Ident,
	pos:    int,
}

// Call is a call to a rule with arguments, e.g. `<greet person "Mr">`.
Call :: struct {
	// name: Production,
	name: Production,
	args: [dynamic]Production,
	pos:  int,
}

// Directive is a directive, e.g. `@import("base")`.
Directive :: struct {
	name: Ident,
	args: [dynamic]Production,
	pos:  int,
}

// Tagged_Production is a production annotated with one or more tags, e.g.
// `a b `name="value"``. pos is the offset of the annotated production, so the
// production reports the position of the element it wraps rather than that of
// the tag written after it.
Tagged_Production :: struct {
	expr: ^Production,
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
expr_pos :: proc(expr: Production) -> int {
	switch v in expr {
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
	case Group_Expr:
		return v.pos
	case Member_Access:
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
		if v.expr != nil do destroy_expr(v.expr)
	case Binding:
		destroy_expr(v.directive)
	case Comment_Group:
		delete(v.list)
	}
}

destroy_expr :: proc(expr: Production) {
	switch v in expr {
	case Ident, String_Lit, Regex_Lit, External_Value:
	case Sequence:
		for e in v.exprs {
			destroy_expr(e)
		}
		delete(v.exprs)
	case Alternative:
		for e in v.exprs {
			destroy_expr(e)
		}
		delete(v.exprs)
	case Optional:
		for e in v.exprs {
			destroy_expr(e)
		}
		delete(v.exprs)
	case Repetition:
		for e in v.exprs {
			destroy_expr(e)
		}
		delete(v.exprs)
	case Group_Expr:
		for e in v.exprs {
			destroy_expr(e)
		}
		delete(v.exprs)
	case Member_Access:
		destroy_expr(v.object^)
		free(v.object)
	case ^Call:
		for e in v.args {
			destroy_expr(e)
		}
		delete(v.args)
		free(v)
	case Directive:
		for e in v.args {
			destroy_expr(e)
		}
		delete(v.args)
	case Tagged_Production:
		destroy_expr(v.expr^)
		free(v.expr)
		delete(v.tag)
	}
}
