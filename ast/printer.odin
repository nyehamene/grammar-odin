package ast

import "core:fmt"
import "core:io"

import "../token"

// Printer writes the AST tree of a parsed grammar source to a writer.
Printer :: struct {
	writer: io.Writer,
	src:    string,
	indent: int,
}

// print_file writes file as an indented tree to writer. Positions are printed
// as `line:column` (column padded) followed by two-space indentation per depth
// level. Comments are printed verbatim so newlines and comments are preserved.
print_file :: proc(writer: io.Writer, src: string, file: ^File) {
	p := Printer {
		writer = writer,
		src    = src,
	}
	io.write_string(writer, "File\n")
	p.indent += 1
	for decl in file.decls {
		print_decl(&p, decl)
	}
	p.indent -= 1
}

print_decl :: proc(p: ^Printer, decl: Decl) {
	switch v in decl {
	case Rule:
		print_rule(p, v)
	case Binding:
		print_header(
			p,
			v.pos,
			fmt.tprintf(
				"BindingDecl: %s = @import(\"%s\")",
				v.ident.name,
				strip_quotes(v.path.value),
			),
		)
	case Comment_Group:
		for c in v.list {
			io.write_string(p.writer, c.text)
			io.write_string(p.writer, "\n")
		}
	}
}

print_production :: proc(p: ^Printer, production: Production) {
	switch v in production {
	case Ident:
		print_header(p, v.pos, fmt.tprintf("Ident: %s", v.name))
	case String_Lit:
		print_header(p, v.pos, fmt.tprintf("StringLit: %s", v.value))
	case Regex_Lit:
		print_header(p, v.pos, fmt.tprintf("RegexLit: %s", v.value))
	case External_Value:
		print_header(p, v.pos, fmt.tprintf("ExternalValue: $%s", v.name))
	case Sequence:
		print_header(p, v.pos, "SequenceProduction")
		p.indent += 1
		for e in v.productions {
			print_production(p, e)
		}
		p.indent -= 1
	case Alternative:
		print_header(p, v.pos, "AlternativeProduction")
		p.indent += 1
		for e in v.productions {
			print_production(p, e)
		}
		p.indent -= 1
	case Optional:
		print_header(p, v.pos, "OptionalProduction")
		p.indent += 1
		print_production(p, v.production^)
		p.indent -= 1
	case Repetition:
		print_header(p, v.pos, "RepetitionProduction")
		p.indent += 1
		print_production(p, v.production^)
		p.indent -= 1
	case Group:
		print_header(p, v.pos, "GroupProduction")
		p.indent += 1
		print_production(p, v.production^)
		p.indent -= 1
	case Qual_Ident:
		print_header(p, v.pos, "MemberExpr")
		p.indent += 1
		print_production(p, v.lhs)
		print_header(p, v.pos, fmt.tprintf("Member: %s", v.rhs.name))
		p.indent -= 1
	case ^Call:
		print_header(p, v.pos, "CallExpr: ")
		switch it in v.ident {
		case Ident:
			print_production(p, it)
		case Qual_Ident:
			print_production(p, it.lhs)
			print_production(p, it.rhs)
		}
		p.indent += 1
		for e in v.args {
			print_production(p, e)
		}
		p.indent -= 1
	case Directive:
		print_header(p, v.pos, fmt.tprintf("DirectiveExpr: @%s", v.ident.name))
		p.indent += 1
		for e in v.args {
			print_production(p, e)
		}
		p.indent -= 1
	case Tagged_Production:
		print_header(p, v.pos, "TaggedProduction")
		p.indent += 1
		print_production(p, v.production^)
		for pair in v.tag {
			print_header(
				p,
				pair.pos,
				fmt.tprintf("TagPair: %s=%s", pair.ident.name, pair.value.value),
			)
		}
		p.indent -= 1
	}
}

// print_header writes a `line:col`, indent and text on one line. The column is
// padded to the same width as fmt "%d:%-4d" in Go's reference printer.
print_header :: proc(p: ^Printer, offset: int, text: string) {
	pos := token.position_at(p.src, offset)
	line := fmt.tprintf("%d:", pos.line)
	col := fmt.tprintf("%d", pos.column)
	io.write_string(p.writer, line)
	io.write_string(p.writer, col)
	for i in len(col) ..< 4 {
		io.write_string(p.writer, " ")
	}
	write_header_line(p, text)
}

// write_header_line writes the indent and the text of a node header, and the
// newline that ends it.
write_header_line :: proc(p: ^Printer, text: string) {
	for i in 0 ..< p.indent {
		io.write_string(p.writer, "  ")
	}
	io.write_string(p.writer, text)
	io.write_string(p.writer, "\n")
}

strip_quotes :: proc(s: string) -> string {
	if len(s) >= 2 && s[0] == '"' && s[len(s) - 1] == '"' {
		return s[1:len(s) - 1]
	}
	return s
}

// Print_Rule writes one rule as an indented tree to writer. It is what
// `grammar expand --tree` prints, since the rule an expansion returns is not part
// of a file.
Print_Rule :: proc(writer: io.Writer, src: string, rule: Rule) {
	p := Printer {
		writer = writer,
		src    = src,
	}
	print_rule(&p, rule)
}

// Print_Normalized_Rule writes one factored rule as an indented tree to writer,
// which is what `grammar normalize --tree` prints.
Print_Normalized_Rule :: proc(writer: io.Writer, src: string, n: Normalized_Rule) {
	p := Printer {
		writer = writer,
		src    = src,
	}
	print_normalized_rule(&p, n)
}

// print_rule writes a rule declaration: its name, its parameters, and its body.
print_rule :: proc(p: ^Printer, rule: Rule) {
	print_header(p, rule.pos, fmt.tprintf("RuleDecl: %s", rule.ident.name))
	p.indent += 1
	for param in rule.params {
		print_header(p, param.pos, fmt.tprintf("Param: %s", param.name))
	}
	print_production(p, rule.production)
	p.indent -= 1
}

// print_normalized_rule writes a factored rule: its leading, one entry per middle,
// and its trailing. The three parts themselves carry no position, since factoring
// has put them somewhere no single production ever was. The productions inside them
// keep the offsets they were parsed at, which say where they were written rather
// than where the factored form will put them.
print_normalized_rule :: proc(p: ^Printer, n: Normalized_Rule) {
	print_text(p, fmt.tprintf("NormalizedRule: %s", n.ident.name))
	p.indent += 1
	for param in n.params {
		print_text(p, fmt.tprintf("Param: %s", param.name))
	}
	print_text(p, "Leading:")
	p.indent += 1
	print_normalized(p, n.leading)
	p.indent -= 1
	print_text(p, "Middle:")
	p.indent += 1
	for middle in n.body {
		print_normalized(p, middle)
	}
	p.indent -= 1
	print_text(p, "Trailing:")
	p.indent += 1
	print_normalized(p, n.trailing)
	p.indent -= 1
}

// print_normalized writes a production of a normalized tree.
print_normalized :: proc(p: ^Printer, n: Normalized_Production) {
	if n.kind == nil {
		print_text(p, "Nothing")
		return
	}
	switch it in n.kind {
	case Nothing:
		print_text(p, "Nothing")
	case Production:
		print_production(p, it)
	case ^Factored:
		print_text(p, "Factored:")
		p.indent += 1
		for middle in it.body {
			print_normalized(p, middle)
		}
		p.indent -= 1
	case ^Grouped:
		print_grouped(p, it)
	}
}

// print_grouped writes a production that holds productions, by its shape. The shape
// is spelled out from the normalized one so that a tree printed this way cannot be
// mistaken for a parsed one.
print_grouped :: proc(p: ^Printer, g: ^Grouped) {
	switch g.shape {
	case .Sequence:
		print_text(p, "NormalizedSequenceProduction")
	case .Group:
		print_text(p, "NormalizedGroupProduction")
	case .Optional:
		print_text(p, "NormalizedOptionalProduction")
	case .Repetition:
		print_text(p, "NormalizedRepetitionProduction")
	case .Tagged:
		print_text(p, "NormalizedTaggedProduction")
	}
	p.indent += 1
	for pair in g.tag[:] {
		print_header(
			p,
			pair.pos,
			fmt.tprintf("TagPair: %s=%s", pair.ident.name, pair.value.value),
		)
	}
	for production in g.productions[:] {
		print_normalized(p, production)
	}
	p.indent -= 1
}

// print_text writes a node header with no position, for a tree whose nodes have
// been moved about.
print_text :: proc(p: ^Printer, text: string) {
	write_header_line(p, text)
}
