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
// A body that takes more than one line is written on lines of its own, the way the
// example grammars and the formatter write one:
//
//	production = a
//	     | b
//	     ;
//	use  = p
//	       ( a | b )
//	       q
//	     ;
//
// The columns are the formatter's: the `=`, every `|` and the `;` sit one past the
// rule's name and parameters, and a production or a part that follows one of them
// starts a column further in (rules 4 and 5 of implementation/08-fmt.md).
//
// The rules written together are lined up on the widest left hand side among them, so
// that the `=` of a file's rules lands on one column. The gap that lines them up goes
// after the name, and each rule is padded out to that width whole; a caller writing a
// single rule passes its own width and nothing is padded.
//
// That is not the formatter's rule 6, which pads each parameter into a cell as wide as
// the widest parameter of its column so that the parameters themselves line up. A file
// of procs therefore comes out of this writer and out of `grammar fmt` with the same
// layout except where the two differ in how the parameters are spaced, which is the one
// place a written rule and a formatted one do not read the same.
//
// A comment between two rules is written where it was written, at its own column, and
// so breaks the alignment it sits in without ending the group the rules share: only
// blank lines end a group in the formatter, and this writer writes no blank lines of
// its own.
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
	return has_empty_middle(n.body)
}

// has_empty_middle reports whether a factored production holds a middle that its
// leading and its trailing left nothing in. Whether the production is a whole rule or
// a group inside one makes no difference to that, or to there being no way to write it.
has_empty_middle :: proc(body: []Normalized_Production) -> bool {
	for middle in body {
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

// Lhs_Width returns how wide the name and parameters decl are declared with, which is
// what the separators of the rules written together are lined up to. A declaration
// that is not a rule has no such left hand side and is given a width of zero, so a
// file of rules is measured by its rules alone.
Lhs_Width :: proc(decl: Decl) -> int {
	rule, is_rule := decl.(Rule)
	if !is_rule do return 0
	return lhs_width(rule.ident, rule.params)
}

// Max_Lhs_Width returns the width a set of declarations is written to: the widest left
// hand side among them.
//
// It is worked out from the parsed tree, which is sound because expansion and
// factorization both carry the name and the parameters of a rule through unchanged, so
// a rule's left hand side is the same width before and after either. That also means a
// rule whose expansion fails still sets the width of the rules around it.
Max_Lhs_Width :: proc(decls: []Decl) -> int {
	width := 0
	for decl in decls {
		width = max(width, Lhs_Width(decl))
	}
	return width
}

// lhs_width returns how wide the name and parameters a rule is declared with are,
// which is what the separators of the rule are lined up past.
lhs_width :: proc(ident: Ident, params: []Ident) -> int {
	width := len(ident.name)
	for param in params {
		width += 1 + len(param.name)
	}
	return width
}

// separator_column returns the column the `=`, the `|` of every alternative line and
// the `;` of a rule are written at: one past the rule's name and parameters.
separator_column :: proc(width: int) -> int {
	return width + 1
}

// write_lhs writes the name and parameters a rule is declared with, padded out to the
// width the rules written together are lined up to.
//
// The name stays where it is and the gap goes after it, so that the last parameter of
// every rule reaches the same column and the separators after it line up. The width is
// the widest left hand side of the group, so this never has to take a gap away.
write_lhs :: proc(w: io.Writer, ident: Ident, params: []Ident, width: int) {
	io.write_string(w, ident.name)
	write_pad(w, width - lhs_width(ident, params))
	for param in params {
		io.write_string(w, " ")
		io.write_string(w, param.name)
	}
}

// write_pad writes count spaces, which is how the writer reaches the column the
// separators of a rule line up on.
write_pad :: proc(w: io.Writer, count: int) {
	for _ in 0 ..< count do io.write_string(w, " ")
}

// write_terminator ends a rule whose body took more than one line, putting the `;`
// on a line of its own at the separator column.
write_terminator :: proc(w: io.Writer, col: int) {
	io.write_string(w, "\n")
	write_pad(w, col)
	io.write_string(w, ";\n")
}

// Write_Rule writes the canonical source of a rule, terminated by a semicolon and
// a newline. A rule whose body is an alternative is written on a line per branch,
// since the branches are what the rule offers a reader to choose between and one line
// hides them among each other. Any other body is written on one line, as it stands.
// The rule is only read.
Write_Rule :: proc(w: io.Writer, r: Rule, width: int) {
	col := separator_column(width)

	// Only a body that is an alternative of branches is written on lines of its own.
	// An alternative nested in a group keeps the line it has always had, since the
	// writer has no bracket depth to indent it by and a `|` line inside parentheses
	// would read as an alternative of the rule rather than of the group.
	branches, is_branches := r.production.(^Alternative)
	if !is_branches {
		write_lhs(w, r.ident, r.params, width)
		io.write_string(w, " = ")
		write_production(w, r.production)
		io.write_string(w, ";\n")
		return
	}

	list := collect_branches(branches)
	defer delete(list)

	write_lhs(w, r.ident, r.params, width)
	io.write_string(w, " = ")
	write_production(w, list[0])
	for branch in list[1:] {
		io.write_string(w, "\n")
		write_pad(w, col)
		io.write_string(w, "| ")
		write_production(w, branch)
	}
	write_terminator(w, col)
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
	for comment in group.list {
		io.write_string(w, comment.text)
		if !strings.has_suffix(comment.text, "\n") {
			io.write_string(w, "\n")
		}
	}
}

// Write_Normalized_Rule writes the canonical source of a factored rule. The leading
// and the trailing are written either side of the middles, which go in a group holding
// an alternative:
//
//	a b c ( d e | f ) y z
//
// A group is left off when there is one middle and it is not empty, so a rule with a
// single branch is written as it stands.
//
// A rule that has a leading or a trailing takes more than one line, one part to a
// line, since showing the parts apart is the point of writing a factored rule:
//
//	use = p
//	      ( a | b )
//	      q
//	    ;
//
// A rule with an empty middle is written as its branches whole instead, since the
// factored form would not parse and dropping the branch would leave out a language
// the rule matches. The tree is only read; the caller frees it with
// destroy_normalized_rule.
Write_Normalized_Rule :: proc(w: io.Writer, n: Normalized_Rule, width: int) {
	write_normalized_rule(w, n, width)
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
		write_production_list(w, it.args, " ")
		io.write_string(w, ")")
	case ^Call:
		write_call(w, it)
	case ^Tagged_Production:
		write_production(w, it.production)
		write_tag_pairs(w, it.tag)
	case Sequence:
		write_production_list(w, it.productions, " ")
	case ^Alternative:
		// The chain leans left, so writing the left then the right gives
		// `a | b | c` with no parentheses between the branches.
		write_production(w, it.lhs)
		io.write_string(w, " | ")
		write_production(w, it.rhs)
	case ^Optional:
		write_wrapped_production(w, "[", "]", it.production)
	case ^Repetition:
		write_wrapped_production(w, "{", "}", it.production)
	case ^Group:
		write_wrapped_production(w, "(", ")", it.production)
	}
}

// inner_space returns the space that goes just inside a grouping symbol when
// something sits between the symbols, which is how the formatter writes them:
// `( a )` and not `(a)`.
inner_space :: proc(count: int) -> string {
	return " " if count > 0 else ""
}

// production_len returns how many productions a production is written as inside a
// grouping symbol: a sequence is written as its own productions, and anything else
// stands as one of them.
production_len :: proc(production: Production) -> int {
	seq, is_sequence := production.(Sequence)
	if !is_sequence do return 1
	return len(seq.productions)
}

// write_wrapped_production writes a production between grouping symbols, with a space
// just inside them when it is written as more than one production, which is how the
// formatter writes them: `[ a b ]` and not `[a b]`, and `( a )` rather than `(a)`.
write_wrapped_production :: proc(w: io.Writer, open, closing: string, production: Production) {
	inner := inner_space(production_len(production))
	io.write_string(w, open)
	io.write_string(w, inner)
	write_production(w, production)
	io.write_string(w, inner)
	io.write_string(w, closing)
}

// write_production_list writes the productions of a list separated by sep.
write_production_list :: proc(w: io.Writer, productions: []Production, sep: string) {
	for production, i in productions {
		if i > 0 do io.write_string(w, sep)
		write_production(w, production)
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
	for arg in call.args {
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
write_normalized_rule :: proc(w: io.Writer, n: Normalized_Rule, width: int) {
	col := separator_column(width)

	if Has_Empty_Middle(n) {
		write_branch_lines(w, col, width, n)
		return
	}

	// A rule with no leading and no trailing is one part, and is written as one line.
	if is_nothing(n.leading) && is_nothing(n.trailing) {
		write_lhs(w, n.ident, n.params, width)
		io.write_string(w, " = ")
		write_middles(w, n.body)
		io.write_string(w, ";\n")
		return
	}

	// Otherwise the parts go one to a line: the leading shares the line the `=` ends,
	// and each part after it is indented a column further, which is where the
	// formatter puts a continuation line that carries no `|` (rule 5 of
	// implementation/08-fmt.md). Showing the parts apart is the point, since they are
	// what the rule was factored into.
	write_lhs(w, n.ident, n.params, width)
	io.write_string(w, " = ")
	if !is_nothing(n.leading) {
		write_normalized(w, n.leading)
		io.write_string(w, "\n")
		write_pad(w, col + 2)
	}
	write_middles(w, n.body)
	if !is_nothing(n.trailing) {
		io.write_string(w, "\n")
		write_pad(w, col + 2)
		write_normalized(w, n.trailing)
	}
	write_terminator(w, col)
}

// write_branch_lines writes a rule as the branches it was factored from, one to a
// line. This is what a rule with an empty middle is written as: the middle has no
// productions to write in the factored form, and leaving the branch out would drop a
// language the rule matches. The branches are alternatives of one another, so they
// get the layout an alternative gets.
write_branch_lines :: proc(w: io.Writer, col, width: int, n: Normalized_Rule) {
	write_lhs(w, n.ident, n.params, width)
	io.write_string(w, " = ")
	write_branch(w, n.leading, n.body[0], n.trailing)
	for middle in n.body[1:] {
		io.write_string(w, "\n")
		write_pad(w, col)
		io.write_string(w, "| ")
		write_branch(w, n.leading, middle, n.trailing)
	}
	write_terminator(w, col)
}

// write_branch writes one branch of a factored rule put back together: the leading,
// its own middle and the trailing, in that order and each one left out when it is
// absent.
write_branch :: proc(
	w: io.Writer,
	leading, middle, trailing: Normalized_Production,
) {
	written := 0
	if !is_nothing(leading) {
		write_normalized(w, leading)
		written += 1
	}
	if !is_nothing(middle) {
		if written > 0 do io.write_string(w, " ")
		write_normalized(w, middle)
		written += 1
	}
	if !is_nothing(trailing) {
		if written > 0 do io.write_string(w, " ")
		write_normalized(w, trailing)
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
		// A production with an empty middle has no factored form to write, so it is
		// written as its branches whole, the same as a rule that has one.
		if has_empty_middle(it.body) {
			for middle, i in it.body {
				if i > 0 do io.write_string(w, " | ")
				write_branch(w, it.leading, middle, it.trailing)
			}
			return
		}
		// A factored production nested in another one keeps its own leading and its
		// own trailing. They are the productions every branch of the alternative it
		// came from shared, so leaving them out drops what the branches had in common
		// and writes a language the rule does not match.
		if !is_nothing(it.leading) {
			write_normalized(w, it.leading)
			io.write_string(w, " ")
		}
		io.write_string(w, "( ")
		write_choice(w, it.body)
		io.write_string(w, " )")
		if !is_nothing(it.trailing) {
			io.write_string(w, " ")
			write_normalized(w, it.trailing)
		}
	case ^Grouped:
		write_grouped(w, it)
	}
}

// write_grouped writes a production that holds productions, by its shape.
write_grouped :: proc(w: io.Writer, g: ^Grouped) {
	switch g.shape {
	case .Sequence:
		write_normalized_list(w, g.productions, " ")
	case .Group:
		// A group holding a factored alternative already carries the parentheses
		// that a factored form writes for itself, so they are not doubled. Any other
		// grouping keeps its own symbols: a bracketed alternative still reads as
		// `[ ( a | b ) ]`.
		if len(g.productions) == 1 {
			_, factored := g.productions[0].kind.(^Factored)
			if factored {
				write_normalized(w, g.productions[0])
				return
			}
		}
		write_wrapped(w, g.productions, "(", ")", " ")
	case .Optional:
		write_wrapped(w, g.productions, "[", "]", " ")
	case .Repetition:
		write_wrapped(w, g.productions, "{", "}", " ")
	case .Tagged:
		// A tag annotates the sequence it closes, so it is written after the
		// production it annotates rather than inside a group.
		for production, i in g.productions {
			if i > 0 do io.write_string(w, " ")
			write_normalized(w, production)
			if i == 0 do write_tag_pairs(w, g.tag)
		}
	}
}

// write_wrapped writes the elements of a grouping production between its symbols.
// An alternative inside a group is one element, so it writes its own branches.
write_wrapped :: proc(
	w: io.Writer,
	productions: []Normalized_Production,
	open, closing, sep: string,
) {
	io.write_string(w, open)
	io.write_string(w, inner_space(len(productions)))
	if sep == " | " {
		write_choice(w, productions)
	} else {
		for production, i in productions {
			if i > 0 do io.write_string(w, sep)
			write_normalized(w, production)
		}
	}
	io.write_string(w, inner_space(len(productions)))
	io.write_string(w, closing)
}

// write_normalized_list writes the productions of a list separated by sep.
write_normalized_list :: proc(w: io.Writer, productions: []Normalized_Production, sep: string) {
	for production, i in productions {
		if i > 0 do io.write_string(w, sep)
		write_normalized(w, production)
	}
}
