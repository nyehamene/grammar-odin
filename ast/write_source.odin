package ast

import "core:io"
import "core:strings"

// This file writes a tree back out as grammar source, which is what
// `grammar expand` and `grammar normalize` print. The spelling follows the
// canonical one the formatter produces (implementation/08-fmt.md), so a written
// rule and a formatted one read the same:
//
//	ident [param...] "=" production ";"
//	ident "=" "@import" "(" string ")" ";"
//
// Two things cannot survive the round trip, and neither is this writer's fault:
//
//   - A comment written inside a rule body. The parser drops those, so the tree
//     never held them. A comment on a line of its own is a Comment_Group
//     declaration and is written back verbatim.
//   - Positions. Everything is written from the node names, so the result parses
//     but its layout is the writer's own.

// Has_Empty_Middle reports whether a factored rule holds a middle that the
// leading and the trailing left nothing in. Such a rule denotes a language one of
// whose branches is matched by the leading and the trailing alone, which has no
// surface syntax: written out it is `( | x )`, which does not parse. A caller
// that writes a normalized rule uses this to say so rather than to leave the
// reader with a file that will not load.
Has_Empty_Middle :: proc(n: Normalized_Rule) -> bool {
	for middle in n.body {
		if is_nothing(middle) do return true
	}
	return false
}

// is_nothing reports whether n is the absence of a production.
is_nothing :: proc(n: Normalized_Production) -> bool {
	if n.kind == nil do return true
	_, absent := n.kind.(Nothing)
	return absent
}

// Write_Rule writes the canonical source of a rule, terminated by a semicolon and
// a newline. The rule is only read.
Write_Rule :: proc(w: io.Writer, r: Rule) {
	io.write_string(w, r.ident.name)
	for param in r.params {
		io.write_string(w, " ")
		io.write_string(w, param.name)
	}
	io.write_string(w, " = ")
	write_production(w, r.expr)
	io.write_string(w, ";\n")
}

// Write_Binding writes the canonical source of an import binding. It is written
// unchanged, since a binding has no body to expand or to factor.
Write_Binding :: proc(w: io.Writer, b: Binding) {
	io.write_string(w, b.ident.name)
	io.write_string(w, " = @import(")
	io.write_string(w, b.path.value)
	io.write_string(w, ");\n")
}

// Write_Comment_Group writes the comments of a declaration back verbatim, one per
// line. A comment the scanner kept its line break is written as it stands, and one
// that did not gets a break of its own.
Write_Comment_Group :: proc(w: io.Writer, group: Comment_Group) {
	for comment in group.list[:] {
		io.write_string(w, comment.text)
		if !strings.has_suffix(comment.text, "\n") {
			io.write_string(w, "\n")
		}
	}
}

// Write_Normalized_Rule writes the canonical source of a factored rule. The
// leading and the trailing are written either side of the middles, which go in a
// group holding an alternative:
//
//	a b c ( d e | f ) y z
//
// A group is left off when there is one middle and it is not empty, so a rule with a
// single branch is written as it stands.
//
// A rule with an empty middle is written as its branches whole instead, since the
// factored form would not parse and dropping the branch would leave out a language
// the rule matches. The tree is only read; the caller frees it with
// destroy_normalized_rule.
Write_Normalized_Rule :: proc(w: io.Writer, n: Normalized_Rule) {
	write_normalized_rule(w, n)
}

// write_production writes a production of a parsed tree.
write_production :: proc(w: io.Writer, p: Production) {
	switch it in p {
	case Ident:
		io.write_string(w, it.name)
	case String_Lit:
		io.write_string(w, it.value)
	case Regex_Lit:
		io.write_string(w, it.value)
	case External_Value:
		write_external(w, it)
	case Qual_Ident:
		io.write_string(w, it.lhs.name)
		io.write_string(w, ".")
		io.write_string(w, it.rhs.name)
	case Directive:
		io.write_string(w, "@")
		io.write_string(w, it.ident.name)
		io.write_string(w, "(")
		write_production_list(w, it.args[:], " ")
		io.write_string(w, ")")
	case ^Call:
		write_call(w, it)
	case Tagged_Production:
		write_production(w, it.expr^)
		write_tag_pairs(w, it.tag[:])
	case Sequence:
		write_production_list(w, it.exprs[:], " ")
	case Alternative:
		write_production_list(w, it.exprs[:], " | ")
	case Optional:
		io.write_string(w, "[")
		io.write_string(w, inner_space(len(it.exprs)))
		write_production_list(w, it.exprs[:], " ")
		io.write_string(w, inner_space(len(it.exprs)))
		io.write_string(w, "]")
	case Repetition:
		io.write_string(w, "{")
		io.write_string(w, inner_space(len(it.exprs)))
		write_production_list(w, it.exprs[:], " ")
		io.write_string(w, inner_space(len(it.exprs)))
		io.write_string(w, "}")
	case Group:
		io.write_string(w, "(")
		io.write_string(w, inner_space(len(it.exprs)))
		write_production_list(w, it.exprs[:], " ")
		io.write_string(w, inner_space(len(it.exprs)))
		io.write_string(w, ")")
	}
}

// inner_space returns the space that goes just inside a grouping symbol when
// something sits between the symbols, which is how the formatter writes them:
// `( a )` and not `(a)`.
inner_space :: proc(count: int) -> string {
	return " " if count > 0 else ""
}

// write_production_list writes the productions of a list separated by sep.
write_production_list :: proc(w: io.Writer, exprs: []Production, sep: string) {
	for expr, i in exprs {
		if i > 0 do io.write_string(w, sep)
		write_production(w, expr)
	}
}

// write_call writes a call to a rule. A call is only here when an expansion did
// not finish, so it is written the way the source spelled it.
write_call :: proc(w: io.Writer, call: ^Call) {
	// The angle brackets of a call are tight, as the formatter writes them: a
	// space goes before the `<` and after the `>`, and none inside.
	io.write_string(w, "<")
	switch name in call.ident {
	case Ident:
		io.write_string(w, name.name)
	case Qual_Ident:
		io.write_string(w, name.lhs.name)
		io.write_string(w, ".")
		io.write_string(w, name.rhs.name)
	}
	for arg in call.args[:] {
		io.write_string(w, " ")
		write_production(w, arg)
	}
	io.write_string(w, ">")
}

// write_tag_pairs writes a run of tag pairs in the canonical spelling, which is
// no space around the `=` and one space between pairs. Nothing is written for an
// empty run, which is what a tag stripped by the normal form leaves behind.
write_tag_pairs :: proc(w: io.Writer, pairs: []Tag_Pair) {
	if len(pairs) == 0 do return
	io.write_string(w, " `")
	for pair, i in pairs {
		if i > 0 do io.write_string(w, "; ")
		io.write_string(w, pair.ident.name)
		io.write_string(w, "=")
		io.write_string(w, pair.value.value)
	}
	io.write_string(w, "`")
}

// external_name returns the canonical spelling of an external value. The scanner
// accepts the name with or without its trailing underscores and the formatter
// writes them, so they are written here too.
// write_external writes an external value. The scanner keeps the name without
// either run of underscores, so the canonical spelling puts them back.
write_external :: proc(w: io.Writer, e: External_Value) {
	io.write_string(w, "__")
	io.write_string(w, e.name)
	io.write_string(w, "__")
}

// write_normalized_rule writes a factored rule as its leading, its middles, and its
// trailing, or as its branches whole when one of them has nothing in the middle.
write_normalized_rule :: proc(w: io.Writer, n: Normalized_Rule) {
	io.write_string(w, n.ident.name)
	for param in n.params {
		io.write_string(w, " ")
		io.write_string(w, param.name)
	}
	io.write_string(w, " = ")

	if Has_Empty_Middle(n) {
		write_branches(w, n)
	} else {
		if !is_nothing(n.leading) {
			write_normalized(w, n.leading)
			io.write_string(w, " ")
		}
		write_middles(w, n.body[:])
		if !is_nothing(n.trailing) {
			io.write_string(w, " ")
			write_normalized(w, n.trailing)
		}
	}
	io.write_string(w, ";\n")
}

// write_branches writes a rule as the branches it was factored from, each one the
// leading, its own middle and the trailing put back together. This is what a rule
// with an empty middle is written as: the middle has no productions to write in the
// factored form, and leaving the branch out would drop a language the rule matches.
write_branches :: proc(w: io.Writer, n: Normalized_Rule) {
	for middle, i in n.body {
		if i > 0 do io.write_string(w, " | ")
		written := 0
		if !is_nothing(n.leading) {
			write_normalized(w, n.leading)
			written += 1
		}
		if !is_nothing(middle) {
			if written > 0 do io.write_string(w, " ")
			write_normalized(w, middle)
			written += 1
		}
		if !is_nothing(n.trailing) {
			if written > 0 do io.write_string(w, " ")
			write_normalized(w, n.trailing)
		}
	}
}

// write_middles writes the middles as a group holding an alternative. The group is
// left off when there is one middle and it is not empty, so a rule with a single
// branch is written as it stands rather than wrapped in a group of one.
write_middles :: proc(w: io.Writer, body: []Normalized_Production) {
	grouped := len(body) != 1 || is_nothing(body[0])
	if !grouped {
		write_normalized(w, body[0])
		return
	}

	io.write_string(w, "( ")
	write_choice(w, body)
	io.write_string(w, " )")
}

// write_choice writes the middles of a choice separated by a pipe. An empty middle
// writes as nothing, which is how a branch the leading and the trailing matched on
// their own reaches the output, so the separator after one loses the space the
// opening symbol already gave it: the result is `( | x )` and not `(  | x )`.
write_choice :: proc(w: io.Writer, body: []Normalized_Production) {
	for middle, i in body {
		if i > 0 {
			if is_nothing(body[i - 1]) {
				io.write_string(w, "| ")
			} else {
				io.write_string(w, " | ")
			}
		}
		write_normalized(w, middle)
	}
}

// write_normalized writes a production of a normalized tree.
write_normalized :: proc(w: io.Writer, n: Normalized_Production) {
	if n.kind == nil do return
	switch it in n.kind {
	case Nothing:
	case Production:
		write_production(w, it)
	case ^Factored:
		io.write_string(w, "( ")
		write_choice(w, it.body[:])
		io.write_string(w, " )")
	case ^Grouped:
		write_grouped(w, it)
	}
}

// write_grouped writes a production that holds productions, by its shape.
write_grouped :: proc(w: io.Writer, g: ^Grouped) {
	switch g.shape {
	case .Sequence:
		write_normalized_list(w, g.exprs[:], " ")
	case .Group:
		// A group holding a factored alternative already carries the parentheses
		// that a factored form writes for itself, so they are not doubled. Any other
		// grouping keeps its own symbols: a bracketed alternative still reads as
		// `[ ( a | b ) ]`.
		if len(g.exprs) == 1 {
			_, factored := g.exprs[0].kind.(^Factored)
			if factored {
				write_normalized(w, g.exprs[0])
				return
			}
		}
		write_wrapped(w, g.exprs[:], "(", ")", " ")
	case .Optional:
		write_wrapped(w, g.exprs[:], "[", "]", " ")
	case .Repetition:
		write_wrapped(w, g.exprs[:], "{", "}", " ")
	case .Tagged:
		// A tag annotates the sequence it closes, so it is written after the
		// production it annotates rather than inside a group.
		for expr, i in g.exprs[:] {
			if i > 0 do io.write_string(w, " ")
			write_normalized(w, expr)
			if i == 0 do write_tag_pairs(w, g.tag[:])
		}
	}
}

// write_wrapped writes the elements of a grouping production between its symbols.
// An alternative inside a group is one element, so it writes its own branches.
write_wrapped :: proc(
	w: io.Writer,
	exprs: []Normalized_Production,
	open, closing, sep: string,
) {
	io.write_string(w, open)
	io.write_string(w, inner_space(len(exprs)))
	if sep == " | " {
		write_choice(w, exprs)
	} else {
		for expr, i in exprs {
			if i > 0 do io.write_string(w, sep)
			write_normalized(w, expr)
		}
	}
	io.write_string(w, inner_space(len(exprs)))
	io.write_string(w, closing)
}

// write_normalized_list writes the productions of a list separated by sep.
write_normalized_list :: proc(w: io.Writer, exprs: []Normalized_Production, sep: string) {
	for expr, i in exprs {
		if i > 0 do io.write_string(w, sep)
		write_normalized(w, expr)
	}
}
