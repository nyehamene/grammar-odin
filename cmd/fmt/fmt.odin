// Package fmtcmd implements `grammar fmt`, the grammar source formatter.
//
// Formatting is driven entirely by the token stream, so line boundaries are
// preserved: blank lines are emitted exactly as written, with the one exception
// that a run of blank lines at the end of the file collapses to a single blank
// line (the golden rule in implementation/08-fmt.md). A run of at least
// `separator` blank lines ends an alignment group; a shorter run is interior
// whitespace inside a group and does not break the alignment (rule 1). The
// source is parsed only to validate it: on a lexical or syntax error the file is
// left untouched and the errors are reported on stderr.
package fmtcmd

import "core:fmt"
import "core:io"
import "core:os"
import "core:strconv"
import "core:strings"

import "../../ast"
import "../../token"
import "../check"

// Fmt_Mode selects where the formatted output is written.
Fmt_Mode :: enum {
	In_Place, // rewrite the input file
	Stdout,   // print to stdout, keep the input file unchanged
}

// Fmt_Item is one formatting target: a path and how to write its output.
Fmt_Item :: struct {
	mode: Fmt_Mode,
	path: string,
}

// run implements `grammar fmt`. Targets are formatted in order; a file that
// fails to parse is reported on stderr and left unmodified, and the process
// exits non-zero after the remaining files have been formatted anyway.
run :: proc(args: []string, stdin: io.Reader, stdout, stderr: io.Writer) -> int {
	items, use_stdin, separator, ok := parse_args(args)
	if !ok {
		io.write_string(stderr, "error: invalid arguments for 'grammar fmt'\n")
		return 1
	}
	defer delete(items)

	if use_stdin {
		data, read_ok := check.read_all(stdin)
		if !read_ok {
			io.write_string(stderr, "error: could not read stdin\n")
			return 1
		}
		defer delete(data)

		text, ok := Format_Text(string(data), "<stdin>", stderr, separator)
		if !ok do return 1
		defer delete(text)
		io.write_string(stdout, text)
		return 0
	}

	if len(items) == 0 {
		io.write_string(stderr, "error: 'fmt' requires a PATH argument\n")
		return 1
	}

	failed := false
	for item in items {
		if !check.is_valid_path(item.path) {
			io.write_string(
				stderr,
				fmt.tprintf(
					"error: invalid path '%s': must be a relative path inside the current working directory\n",
					item.path,
				),
			)
			failed = true
			continue
		}

		data, err := os.read_entire_file_from_path(item.path, context.allocator)
		if err != nil {
			io.write_string(stderr, fmt.tprintf("error: could not read '%s'\n", item.path))
			failed = true
			continue
		}
		src := string(data)

		text, ok := Format_Text(src, item.path, stderr, separator)
		if !ok {
			delete(data)
			failed = true
			continue
		}

		switch item.mode {
		case .Stdout:
			io.write_string(stdout, text)
		case .In_Place:
			if text != src {
				if werr := os.write_entire_file(item.path, text); werr != nil {
					io.write_string(stderr, fmt.tprintf("error: could not write '%s'\n", item.path))
					failed = true
				}
			}
		}

		delete(data)
		delete(text)
	}

	if failed do return 1
	return 0
}

// parse_args parses the fmt arguments. `--stdout` applies to the path that
// follows it; `--stdin` cannot be combined with a path or `--stdout`, but it
// accepts `-s`/`--separator`. A separator below 1 is ignored, leaving the
// default of 1.
parse_args :: proc(args: []string) -> (items: [dynamic]Fmt_Item, use_stdin: bool, separator: int, ok: bool) {
	items = make([dynamic]Fmt_Item)
	mode := Fmt_Mode.In_Place
	separator = 1

	i := 0
	for i < len(args) {
		arg := args[i]
		switch {
		case arg == "--stdin":
			if use_stdin || len(items) > 0 || mode == .Stdout {
				return {}, {}, 0, false
			}
			use_stdin = true
		case arg == "--stdout":
			mode = .Stdout
		case arg == "-s" || arg == "--separator":
			i += 1
			if i >= len(args) {
				return {}, {}, 0, false
			}
			n, parsed := strconv.parse_int(args[i])
			if !parsed {
				return {}, {}, 0, false
			}
			separator = max(n, 1)
		case strings.has_prefix(arg, "--separator="):
			n, parsed := strconv.parse_int(arg[len("--separator="):])
			if !parsed {
				return {}, {}, 0, false
			}
			separator = max(n, 1)
		case strings.has_prefix(arg, "-"):
			return {}, {}, 0, false
		case:
			append(&items, Fmt_Item{mode = mode, path = arg})
			mode = .In_Place
		}
		i += 1
	}

	if mode == .Stdout do return {}, {}, 0, false
	return items, use_stdin, separator, true
}

// Format_Text validates src and returns its formatted text. On a lexical or
// syntax error, the diagnostics are reported on stderr and ok is false. The
// returned string is owned by the caller and must be freed with delete.
// separator is the number of blank lines that ends an alignment group.
Format_Text :: proc(src, name: string, stderr: io.Writer, separator: int = 1) -> (text: string, ok: bool) {
	tokens, lex_errors := token.scan(src)
	defer delete(tokens)
	defer delete(lex_errors)

	file, parse_errors := ast.parse_file(src, tokens[:])
	defer ast.destroy_file(&file)
	defer delete(parse_errors)

	failed := false
	for e in lex_errors {
		pos := token.position_at(src, e.offset)
		io.write_string(
			stderr,
			fmt.tprintf("%s:%d:%d: %s\n", name, pos.line, pos.column, e.message),
		)
		failed = true
	}
	for e in parse_errors {
		pos := token.position_at(src, e.offset)
		io.write_string(
			stderr,
			fmt.tprintf("%s:%d:%d: %s\n", name, pos.line, pos.column, e.message),
		)
		failed = true
	}
	if failed do return "", false

	return layout(src, tokens[:], separator), true
}

// Line_Kind describes how a source line is laid out.
Line_Kind :: enum {
	Blank,         // no tokens
	Comment,       // a "//" comment on its own line
	Header,        // contains the rule separator `=`
	Pipe,          // a vertical alternative that starts with `|`
	Lone_Semicolon, // a rule terminator `;` on its own line
	Body,          // any other continuation line
}

// classify maps the tokens starting a line to its layout kind.
classify :: proc(line: []token.Token) -> Line_Kind {
	if len(line) == 0 do return .Blank
	if line[0].kind == .Comment do return .Comment
	if line[0].kind == .Pipe do return .Pipe
	if len(line) == 1 && line[0].kind == .Semicolon do return .Lone_Semicolon
	for t in line {
		if t.kind == .Equal do return .Header
	}
	return .Body
}

// layout reformats src line by line. Tokens never span lines, so bucketing them
// by their start line and emitting one output line per input line guarantees
// the golden rule: blank lines are reproduced verbatim and no newline is ever
// added, with the single exception that a run of blank lines at the end of the
// file collapses to one.
layout :: proc(src: string, tokens: []token.Token, separator: int) -> string {
	offsets := line_offsets(src)
	defer delete(offsets)
	n_lines := len(offsets)

	// Bucket tokens by the source line they start on. The scanner guarantees a
	// token never spans a newline, so a token belongs to exactly one line.
	groups := make([dynamic][dynamic]token.Token, n_lines)
	defer delete(groups)
	defer for g in groups do delete(g)

	for tok in tokens {
		if tok.kind == .EOF do continue
		line := token.position_at(src, tok.start).line - 1
		append(&groups[line], tok)
	}

	kinds := make([dynamic]Line_Kind, n_lines)
	defer delete(kinds)
	for i in 0 ..< n_lines {
		kinds[i] = classify(groups[i][:])
	}

	// align[line] is the column that `=`, `|`, `;` and continuations of a group
	// are aligned to. A group is a maximal run of lines not ended by a blank
	// line run of at least `separator` lines; the column is the widest rule name
	// in the group.
	align := make([dynamic]int, n_lines)
	defer delete(align)
	compute_align(kinds[:], groups[:], src, align[:], separator)

	nl := newline_style(src)
	b := strings.builder_make()
	first := true

	// The final fragment after a trailing newline is a terminator, not a blank
	// line, so it never participates in group or blank-line handling.
	eff_n := n_lines
	if strings.has_suffix(src, "\n") do eff_n -= 1

	// Blank lines are reproduced as written, except that a run at the end of the
	// file collapses to a single blank line (golden rule). Count that run so it
	// can be emitted separately.
	trailing := 0
	for i := eff_n - 1; i >= 0; i -= 1 {
		if kinds[i] != .Blank do break
		trailing += 1
	}
	cut := eff_n - trailing

	for i in 0 ..< eff_n {
		if kinds[i] == .Blank {
			if i < cut do write_line(&b, "", &first, nl)
			continue
		}
		line := render_line(groups[i][:], kinds[i], align[i], i, src, offsets[:], nl)
		write_line(&b, line, &first, nl)
		delete(line)
	}

	if trailing > 0 {
		write_line(&b, "", &first, nl)
	}

	if strings.has_suffix(src, "\n") {
		strings.write_string(&b, nl)
	}
	res := strings.clone(strings.to_string(b))
	strings.builder_destroy(&b)
	return res
}

// write_line writes one output line (without its trailing newline) to b,
// separating it from any previous line by a newline.
write_line :: proc(b: ^strings.Builder, line: string, first: ^bool, nl: string) {
	if !first^ {
		strings.write_string(b, nl)
	}
	first^ = false
	strings.write_string(b, line)
}

// line_offsets returns the byte offset where each line of src begins. A final
// offset after a trailing newline is included, so the count of offsets equals
// the number of logical lines.
line_offsets :: proc(src: string) -> (offsets: [dynamic]int) {
	offsets = make([dynamic]int, 0, strings.count(src, "\n") + 1)
	append(&offsets, 0)
	for r, i in src {
		if r == '\n' {
			append(&offsets, i + 1)
		}
	}
	return
}

// newline_style returns the line ending used by src.
newline_style :: proc(src: string) -> string {
	if strings.contains(src, "\r\n") do return "\r\n"
	return "\n"
}

// compute_align fills align with the alignment column of the group each line
// belongs to. A run of at least `separator` blank lines ends a group; a shorter
// run is interior whitespace inside a group and does not end it. Blank lines
// get no column.
compute_align :: proc(kinds: []Line_Kind, groups: [][dynamic]token.Token, src: string, align: []int, separator: int) {
	n_lines := len(kinds)
	block_start := 0
	in_block := false
	col := 0
	blank_run := 0
	run_start := 0
	for i in 0 ..< n_lines {
		if kinds[i] == .Blank {
			if blank_run == 0 do run_start = i
			blank_run += 1
			// Only a run that reaches the threshold ends the group (rule 1).
			if blank_run >= separator && in_block {
				for j in block_start ..< run_start {
					align[j] = col + 1
				}
				in_block = false
				col = 0
			}
			continue
		}
		blank_run = 0
		if !in_block {
			block_start = i
			in_block = true
			col = 0
		}
		if kinds[i] == .Header {
			eq := first_equal(groups[i][:])
			lhs := render_tokens(groups[i][:eq], src)
			width := len(lhs)
			delete(lhs)
			col = max(col, width)
		}
	}
	if in_block {
		// The `=`, `|` and `;` of a block sit one column past the widest rule
		// name, so every separator is preceded by at least one space.
		for j in block_start ..< n_lines {
			align[j] = col + 1
		}
	}
}

// first_equal returns the index of the first `=` token in line.
first_equal :: proc(line: []token.Token) -> int {
	for t, i in line {
		if t.kind == .Equal do return i
	}
	return len(line)
}

// render_line renders a single source line into a string. Comment lines are
// copied verbatim; every other line is reconstructed from its tokens and
// aligned to col.
render_line :: proc(
	line: []token.Token,
	kind: Line_Kind,
	col, i: int,
	src: string,
	offsets: []int,
	nl: string,
) -> string {
	switch kind {
	case .Comment:
		start := offsets[i]
		end := len(src)
		if i + 1 < len(offsets) {
			end = offsets[i + 1] - 1
		}
		// Keep the comment verbatim but trim its line ending.
		return strings.clone(strings.trim_right(src[start:end], "\r \t"))

	case .Header:
		eq := first_equal(line)
		b := strings.builder_make()
		lhs := render_tokens(line[:eq], src)
		w := len(lhs)
		strings.write_string(&b, lhs)
		delete(lhs)
		for _ in 0 ..< max(col - w, 0) {
			strings.write_string(&b, " ")
		}
		strings.write_string(&b, "=")
		if eq + 1 < len(line) {
			strings.write_string(&b, " ")
			rhs := render_tokens(line[eq + 1:], src)
			strings.write_string(&b, rhs)
			delete(rhs)
		}
		res := strings.clone(strings.to_string(b))
		strings.builder_destroy(&b)
		return res

	case .Pipe:
		return pad_and_render(line, col, src)

	case .Body:
		// Rule 5: a continuation line carries no leading `|`, so it is indented
		// one column past the separator column. That makes it read as a
		// continuation of the alternative above it instead of as a sibling of
		// the `|` lines.
		return pad_and_render(line, col + 2, src)

	case .Lone_Semicolon:
		b := strings.builder_make()
		for _ in 0 ..< col {
			strings.write_string(&b, " ")
		}
		strings.write_string(&b, ";")
		res := strings.clone(strings.to_string(b))
		strings.builder_destroy(&b)
		return res

	case .Blank:
		return ""
	}
	return ""
}

// pad_and_render indents a line to col and appends its rendered tokens. The
// returned string is owned by the caller.
pad_and_render :: proc(line: []token.Token, col: int, src: string) -> string {
	b := strings.builder_make()
	for _ in 0 ..< col {
		strings.write_string(&b, " ")
	}
	body := render_tokens(line, src)
	strings.write_string(&b, body)
	delete(body)
	res := strings.clone(strings.to_string(b))
	strings.builder_destroy(&b)
	return res
}

// render_tokens reconstructs the source text of a run of tokens. A single space
// is written between neighbouring tokens except around `.`, before `;`, inside
// a rule call `<...>`, after `@`, and inside a call-like `@import(...)` pair.
// The returned string is owned by the caller.
render_tokens :: proc(line: []token.Token, src: string) -> string {
	b := strings.builder_make()
	// Stack marking whether each open paren is a tight `@import(...)` paren.
	tight: [dynamic]bool
	defer delete(tight)

	for i in 0 ..< len(line) {
		tok := line[i]
		// A directive call such as `@import(...)` stays tight; a group
		// parentesis gets a space inside (rule 2).
		paren_tight := tok.kind == .LParen && i >= 2 && line[i - 1].kind == .Ident && line[i - 2].kind == .At
		if i > 0 {
			if space_between(line[i - 1].kind, tok.kind, paren_tight, tight[:]) {
				strings.write_string(&b, " ")
			}
		}
		if tok.kind == .LParen {
			append(&tight, paren_tight)
		} else if tok.kind == .RParen {
			if len(tight) > 0 {
				resize(&tight, len(tight) - 1)
			}
		}
		lex := token.lexeme(tok, src)
		strings.write_string(&b, lex)
		if tok.kind == .External && !strings.has_suffix(lex, "__") {
			// Externals are canonically written with a trailing "__"; supply it
			// when the source omits it.
			strings.write_string(&b, "__")
		}
	}
	res := strings.clone(strings.to_string(b))
	strings.builder_destroy(&b)
	return res
}

// space_between reports whether a space separates the token immediately before
// and at the current position. paren_tight marks a `(` that is part of a tight
// `@import(...)` call; tight holds the tight/group markers for parens opened
// earlier on the line, so a matching `)` closes tight.
space_between :: proc(prev, cur: token.Kind, paren_tight: bool, tight: []bool) -> bool {
	if prev == .Dot || cur == .Dot do return false
	if cur == .Semicolon do return false
	if prev == .At do return false
	if prev == .Lt || cur == .Gt do return false
	if prev == .Gt do return true
	if cur == .Lt do return true
	if cur == .LParen {
		// A tight `@import(...)` call stays glued to its name; other `(` are
		// grouping symbols surrounded by spaces on both sides.
		return !paren_tight
	}
	if prev == .LParen {
		return len(tight) == 0 || !tight[len(tight) - 1]
	}
	if cur == .RParen {
		return len(tight) == 0 || !tight[len(tight) - 1]
	}
	if prev == .RParen do return true
	if prev == .LBrack || prev == .LBrace do return true
	if cur == .RBrack || cur == .RBrace do return true
	return true
}