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
		print_header(p, v.pos, fmt.tprintf("RuleDecl: %s", v.ident.name))
		p.indent += 1
		for param in v.params {
			print_header(p, param.pos, fmt.tprintf("Ident: %s", param.name))
		}
		print_expr(p, v.expr)
		p.indent -= 1
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

print_expr :: proc(p: ^Printer, expr: Production) {
	switch v in expr {
	case Ident:
		print_header(p, v.pos, fmt.tprintf("Ident: %s", v.name))
	case String_Lit:
		print_header(p, v.pos, fmt.tprintf("StringLit: %s", v.value))
	case Regex_Lit:
		print_header(p, v.pos, fmt.tprintf("RegexLit: %s", v.value))
	case External_Value:
		print_header(p, v.pos, fmt.tprintf("ExternalValue: $%s", v.name))
	case Sequence:
		print_header(p, v.pos, "SequenceExpr")
		p.indent += 1
		for e in v.exprs {
			print_expr(p, e)
		}
		p.indent -= 1
	case Alternative:
		print_header(p, v.pos, "AlternativeExpr")
		p.indent += 1
		for e in v.exprs {
			print_expr(p, e)
		}
		p.indent -= 1
	case Optional:
		print_header(p, v.pos, "OptionalExpr")
		p.indent += 1
		for e in v.exprs {
			print_expr(p, e)
		}
		p.indent -= 1
	case Repetition:
		print_header(p, v.pos, "RepetitionExpr")
		p.indent += 1
		for e in v.exprs {
			print_expr(p, e)
		}
		p.indent -= 1
	case Group:
		print_header(p, v.pos, "GroupExpr")
		p.indent += 1
		for e in v.exprs {
			print_expr(p, e)
		}
		p.indent -= 1
	case Qual_Ident:
		print_header(p, v.pos, "MemberExpr")
		p.indent += 1
		print_expr(p, v.lhs)
		print_header(p, v.pos, fmt.tprintf("Member: %s", v.rhs.name))
		p.indent -= 1
	case ^Call:
		print_header(p, v.pos, "CallExpr: ")
		switch it in v.ident {
		case Ident:
			print_expr(p, it)
		case Qual_Ident:
			print_expr(p, it.lhs)
			print_expr(p, it.rhs)
		}
		p.indent += 1
		for e in v.args {
			print_expr(p, e)
		}
		p.indent -= 1
	case Directive:
		print_header(p, v.pos, fmt.tprintf("DirectiveExpr: @%s", v.ident.name))
		p.indent += 1
		for e in v.args {
			print_expr(p, e)
		}
		p.indent -= 1
	case Tagged_Production:
		print_header(p, v.pos, "TaggedExpr")
		p.indent += 1
		print_expr(p, v.expr^)
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
