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
	if is_lone_semicolon(line) do return .Lone_Semicolon
	for t in line {
		if t.kind == .Equal do return .Header
	}
	return .Body
}

// is_lone_semicolon reports whether line is a rule terminator, optionally
// followed by a trailing comment. The comment does not change what the line is,
// so it must not push the line out of the separator column and into the
// continuation indent.
is_lone_semicolon :: proc(line: []token.Token) -> bool {
	if len(line) == 0 || line[0].kind != .Semicolon do return false
	for t in line[1:] {
		if t.kind != .Comment do return false
	}
	return true
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
	// in the group. header_lhs[line] holds the left hand side of a rule header
	// with its name and parameters padded to the group's columns (rule 6); it is
	// empty for every other line.
	align := make([dynamic]int, n_lines)
	defer delete(align)
	header_lhs := make([dynamic]string, n_lines)
	defer delete(header_lhs)
	defer for h in header_lhs do if len(h) > 0 do delete(h)
	compute_align(kinds[:], groups[:], src, align[:], header_lhs[:], separator)

	// indent[line] is the column the line's leading token is written at. At the rule
	// level it is the alignment column for `|` and `;` and two past it for a
	// continuation; inside a group, repetition, optional or call it is measured from
	// the opening delimiter instead (rule 9). It is computed from align, and the tag
	// columns are measured from it, so it sits between the two.
	indent := make([dynamic]int, n_lines)
	defer delete(indent)
	compute_indents(kinds[:], groups[:], src, align[:], indent[:])

	// tag_col[line] is the column the tag of that line starts in, or -1 when the
	// line holds no tag or its rule has fewer than two tags to line up (rule 8).
	tag_col := make([dynamic]int, n_lines)
	defer delete(tag_col)
	compute_tag_columns(kinds[:], groups[:], src, align[:], indent[:], tag_col[:])

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
		line := render_line(
			groups[i][:],
			kinds[i],
			align[i],
			indent[i],
			header_lhs[i],
			tag_col[i],
			i,
			src,
			offsets[:],
			nl,
		)
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
// belongs to, and header_lhs with the padded left hand side of every rule
// header. A run of at least `separator` blank lines ends a group; a shorter run
// is interior whitespace inside a group and does not end it. Blank lines get no
// column.
compute_align :: proc(
	kinds: []Line_Kind,
	groups: [][dynamic]token.Token,
	src: string,
	align: []int,
	header_lhs: []string,
	separator: int,
) {
	n_lines := len(kinds)
	block_start := 0
	in_block := false
	blank_run := 0
	run_start := 0
	for i in 0 ..< n_lines {
		if kinds[i] == .Blank {
			if blank_run == 0 do run_start = i
			blank_run += 1
			// Only a run that reaches the threshold ends the group (rule 1).
			if blank_run >= separator && in_block {
				close_group(kinds[:], groups[:], src, align[:], header_lhs[:], block_start, run_start)
				in_block = false
			}
			continue
		}
		blank_run = 0
		if !in_block {
			block_start = i
			in_block = true
		}
	}
	if in_block {
		close_group(kinds[:], groups[:], src, align[:], header_lhs[:], block_start, n_lines)
	}
}

// close_group lays out the header lines of the group spanning [start, end) and
// gives every line of it its alignment column. The column is one past the
// widest header, so every separator is preceded by at least one space.
close_group :: proc(
	kinds: []Line_Kind,
	groups: [][dynamic]token.Token,
	src: string,
	align: []int,
	header_lhs: []string,
	start, end: int,
) {
	// Rule 6: every header of the group is written to the width of the widest left
	// hand side among them, so the value separator of each lands on one column. The
	// gap that does it goes after the name, so the name stays where it was written and
	// the parameters move out to reach the column: a rule that declares fewer of them
	// still ends there, and the parameters of a rule are not spaced out among
	// themselves to line up with those of a neighbour.
	lhs_w := 0

	// First pass: the widest left hand side in the group.
	for i in start ..< end {
		if kinds[i] != .Header do continue
		lhs := header_tokens(groups[i][:])
		if len(lhs) == 0 do continue
		lhs_w = max(lhs_w, lhs_width(lhs, src))
	}

	// Second pass: render each header lhs. Every one of them is written to lhs_w, so
	// that is the group alignment column for the =, the |, the ; and the continuations
	// as well, one past it so every separator keeps a space before it.
	for i in start ..< end {
		if kinds[i] != .Header do continue
		header_lhs[i] = pad_header(header_tokens(groups[i][:]), src, lhs_w)
	}

	for j in start ..< end {
		align[j] = lhs_w + 1
	}
}

// header_tokens returns the tokens before the `=` of a header line, which is its
// left hand side: a rule name followed by the parameters it declares. The result
// aliases the line and must not be freed.
header_tokens :: proc(line: []token.Token) -> []token.Token {
	return line[:first_equal(line)]
}

// pad_header renders lhs, the name followed by the parameters it declares, padded out
// to width. The gap goes after the name and not at the end of the header, so that the
// name stays where it was written and the last parameter of every header of the group
// reaches the same column. A header that declares no parameters has nothing after the
// gap, so the gap is the whole of it and the name is written out to width.
pad_header :: proc(lhs: []token.Token, src: string, width: int) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	strings.write_string(&b, token.lexeme(lhs[0], src))
	for _ in 0 ..< width - lhs_width(lhs, src) {
		strings.write_string(&b, " ")
	}
	for j in 1 ..< len(lhs) {
		strings.write_string(&b, " ")
		strings.write_string(&b, token.lexeme(lhs[j], src))
	}
	return strings.clone(strings.to_string(b))
}

// lhs_width returns how wide the name and parameters of a header are written, which is
// the width every header of a group is padded out to.
lhs_width :: proc(lhs: []token.Token, src: string) -> int {
	width := len(token.lexeme(lhs[0], src))
	for j in 1 ..< len(lhs) {
		width += 1 + len(token.lexeme(lhs[j], src))
	}
	return width
}

// first_equal returns the index of the first `=` token in line.
first_equal :: proc(line: []token.Token) -> int {
	for t, i in line {
		if t.kind == .Equal do return i
	}
	return len(line)
}

// first_tag returns the index of the tag in line, or -1 when the line holds none.
// A tag annotates the last element of a production, so a line holds at most one.
first_tag :: proc(line: []token.Token) -> int {
	for t, i in line {
		if t.kind == .Tag do return i
	}
	return -1
}

// Construct is one grouping symbol left open across a line break, remembered with
// the column it is opened at once the line is rendered. Rule 9 lays the contents of
// a group, repetition, optional or call out relative to that column, so a `|` line
// and a lone closing delimiter land on it while a continuation lands two past it.
Construct :: struct {
	o:      int,
	closer: token.Kind,
}

// compute_indents fills indent with the column each line's leading token is written
// at (rule 9). The rule itself is the construct at the bottom of the stack, opened
// at its alignment column, so the rule level is laid out by the same rule as a
// group, repetition, optional or call: continuation lines two past the opening
// column, and `|`, `;` and a lone closing delimiter on it.
//
// The column a construct opens at is where its delimiter lands once the line is
// rendered, which is not where it was written in the source: rule 6 pads the left
// hand side, so the delimiter of a rule header moves to the group's column. The
// token scan measures that, one line at a time.
compute_indents :: proc(
	kinds: []Line_Kind,
	groups: [][dynamic]token.Token,
	src: string,
	align: []int,
	indent: []int,
) {
	stack := make([dynamic]Construct, 0, 8)
	defer delete(stack)

	for i in 0 ..< len(kinds) {
		switch kinds[i] {
		case .Blank, .Comment:
			indent[i] = 0
		case .Header:
			// A header starts a rule, so nothing from the previous one is open.
			resize(&stack, 0)
			append(&stack, Construct{o = align[i], closer = .Semicolon})
			indent[i] = 0
			eq := first_equal(groups[i][:])
			scan_constructs(groups[i][eq + 1:], align[i] + 2, src, &stack)
		case .Pipe, .Body, .Lone_Semicolon:
			top := align[i]
			if len(stack) > 0 do top = stack[len(stack) - 1].o

			line := groups[i][:]
			on_open := kinds[i] == .Lone_Semicolon
			if len(line) > 0 && (is_closer(line[0].kind) || line[0].kind == .Pipe) {
				on_open = true
			}
			indent[i] = on_open ? top : top + 2
			scan_constructs(line, indent[i], src, &stack)
		}
	}
}

// is_closer reports whether kind closes a group, repetition, optional or call.
is_closer :: proc(kind: token.Kind) -> bool {
	#partial switch kind {
	case .RParen, .RBrack, .RBrace, .Gt:
		return true
	case:
		return false
	}
}

// scan_constructs walks one rendered line, pushing each grouping symbol it opens
// and popping the innermost construct each closer ends, so compute_indents knows
// the column every construct is opened at. The width of the tokens before a
// delimiter follows render_tokens, so a tight `@import(...)` paren, the canonical
// spelling of a tag and the trailing `__` of an external all measure the way
// render_line writes them.
scan_constructs :: proc(
	line: []token.Token,
	start_col: int,
	src: string,
	stack: ^[dynamic]Construct,
) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	tight: [dynamic]bool
	defer delete(tight)

	for tok, i in line {
		paren_tight :=
			tok.kind == .LParen && i >= 2 && line[i - 1].kind == .Ident && line[i - 2].kind == .At
		if i > 0 && space_between(line[i - 1].kind, tok.kind, paren_tight, tight[:]) {
			strings.write_string(&b, " ")
		}
		col := start_col + strings.builder_len(b)

		#partial switch tok.kind {
		case .LParen:
			append(&tight, paren_tight)
			if !paren_tight do append(stack, Construct{o = col, closer = .RParen})
		case .RParen:
			if len(tight) > 0 {
				was_tight := tight[len(tight) - 1]
				resize(&tight, len(tight) - 1)
				if !was_tight do pop_construct(stack)
			}
		case .LBrack:
			append(stack, Construct{o = col, closer = .RBrack})
		case .LBrace:
			append(stack, Construct{o = col, closer = .RBrace})
		case .Lt:
			append(stack, Construct{o = col, closer = .Gt})
		case .RBrack, .RBrace, .Gt:
			pop_construct(stack)
		case:
		}

		if tok.kind == .Tag {
			write_tag(&b, tok, src)
			continue
		}
		lex := token.lexeme(tok, src)
		strings.write_string(&b, lex)
		if tok.kind == .External && !strings.has_suffix(lex, "__") {
			strings.write_string(&b, "__")
		}
	}
}

// pop_construct drops the innermost open construct, if any.
pop_construct :: proc(stack: ^[dynamic]Construct) {
	if len(stack^) > 0 do resize(stack, len(stack^) - 1)
}

// compute_tag_columns fills tag_col with the column the tag of each line starts in.
// Every tag of a rule shares one column, so that a production arranged over several
// lines has its tags read down the page (rule 8).
//
// A rule with fewer than two tags has nothing to line up, so its tags stay where
// they were written and its lines get -1. Its lines are already indented to the
// separator column, and padding a lone tag would only move it away from the
// production it annotates.
//
// The column depends on how wide each line is once laid out, so this runs after
// compute_align has filled the alignment columns and the padded header left hand
// sides the prefix widths are measured from.
compute_tag_columns :: proc(
	kinds: []Line_Kind,
	groups: [][dynamic]token.Token,
	src: string,
	align: []int,
	indent: []int,
	tag_col: []int,
) {
	for h in 0 ..< len(kinds) {
		if kinds[h] != .Header do continue
		end := rule_end(kinds[:], h)

		tags := 0
		for i in h ..< end {
			if first_tag(groups[i][:]) >= 0 do tags += 1
		}
		if tags < 2 {
			for i in h ..< end do tag_col[i] = -1
			continue
		}

		widest := 0
		for i in h ..< end {
			tag := first_tag(groups[i][:])
			if tag < 0 do continue
			widest = max(widest, tag_prefix_width(kinds[i], groups[i][:], tag, src, indent[i], align[i]))
		}
		// One space past the widest line keeps the tag off whatever it follows.
		for i in h ..< end {
			if first_tag(groups[i][:]) >= 0 do tag_col[i] = widest + 1
		}
	}
}

// rule_end returns the line at which the rule declared at header stops, which is
// the next header, blank line or comment line, or the end of the file. A rule
// separator on a line of its own and the continuation lines above it belong to the
// rule.
rule_end :: proc(kinds: []Line_Kind, header: int) -> int {
	for i in header + 1 ..< len(kinds) {
		switch kinds[i] {
		case .Header, .Blank, .Comment:
			return i
		case .Pipe, .Body, .Lone_Semicolon:
		}
	}
	return len(kinds)
}

// tag_prefix_width returns how wide the part of a line before its tag is once the
// line is laid out: the indent the line is written at, plus the tokens between the
// start of its body and the tag.
tag_prefix_width :: proc(
	kind: Line_Kind,
	line: []token.Token,
	tag: int,
	src: string,
	indent, align: int,
) -> int {
	// A header writes its `=` at the alignment column and its body a space past it;
	// every other line starts at the column compute_indents laid it out at (rule 9).
	head := indent
	start := 0
	switch kind {
	case .Header:
		head = align + 2
		start = first_equal(line) + 1
	case .Body:
		head = indent
	case .Pipe, .Lone_Semicolon, .Comment, .Blank:
	}

	rendered := render_tokens(line[start:tag], src)
	defer delete(rendered)
	return head + len(rendered)
}

// render_line renders a single source line into a string. Comment lines are
// copied verbatim; every other line is reconstructed from its tokens and
// aligned to col. lhs is the padded left hand side compute_align prepared for a
// rule header, and is empty for every other kind. tag_col is the column the line's
// tag starts in, or -1 to leave the tag where the tokens put it (rule 8). indent
// is the column the line's leading token is written at: the alignment column for a
// `|`, a `;` or a lone closing delimiter, and two past it for a continuation
// (rules 5 and 9).
render_line :: proc(
	line: []token.Token,
	kind: Line_Kind,
	col: int,
	indent: int,
	lhs: string,
	tag_col: int,
	i: int,
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
		head := lhs
		if len(head) == 0 {
			head = render_tokens(line[:eq], src)
			defer delete(head)
		}
		b := strings.builder_make()
		strings.write_string(&b, head)
		for _ in 0 ..< max(col - len(head), 0) {
			strings.write_string(&b, " ")
		}
		strings.write_string(&b, "=")
		if eq + 1 < len(line) {
			strings.write_string(&b, " ")
		}
		// A tag on a header is on the right hand side, so it is written from
		// there: the index shifts by the separator and the header's own tokens.
		if tag := first_tag(line); tag > eq && tag_col >= 0 {
			write_body_with_tag(&b, line[eq+1:], tag-eq-1, tag_col, src)
		} else if eq + 1 < len(line) {
			rhs := render_tokens(line[eq + 1:], src)
			strings.write_string(&b, rhs)
			delete(rhs)
		}
		res := strings.clone(strings.to_string(b))
		strings.builder_destroy(&b)
		return res

	case .Pipe:
		if tag := first_tag(line); tag >= 0 && tag_col >= 0 {
			return pad_and_render_with_tag(line, indent, tag, tag_col, src)
		}
		return pad_and_render(line, indent, src)

	case .Body:
		// Rule 5: a continuation line carries no leading `|`, so it is written
		// two past the line its constructs open at. That makes it read as a
		// continuation of the alternative above it instead of as a sibling of the
		// `|` lines. Rule 9 scopes the same layout inside a group, repetition,
		// optional or call, so the column comes from compute_indents.
		if tag := first_tag(line); tag >= 0 && tag_col >= 0 {
			return pad_and_render_with_tag(line, indent, tag, tag_col, src)
		}
		return pad_and_render(line, indent, src)

	case .Lone_Semicolon:
		// The terminator lands on the column `|` and `=` land on, and anything
		// trailing it, a comment in practice, renders after it.
		return pad_and_render(line, indent, src)

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

// pad_and_render_with_tag is pad_and_render with the tag at index tag of the line
// written in column tag_col instead of where its neighbours put it. The returned
// string is owned by the caller.
pad_and_render_with_tag :: proc(
	line: []token.Token,
	col, tag, tag_col: int,
	src: string,
) -> string {
	b := strings.builder_make()
	for _ in 0 ..< col {
		strings.write_string(&b, " ")
	}
	write_body_with_tag(&b, line, tag, tag_col, src)
	res := strings.clone(strings.to_string(b))
	strings.builder_destroy(&b)
	return res
}

// write_body_with_tag appends the body of a line to b with the tag at index tag
// written in column tag_col (rule 8). The tokens before it are rendered, the line
// is padded out to the column, the tag is written in its canonical spelling, and
// whatever follows it is rendered after. A tag never sits inside a group, so no
// parenthesis is open across it and rendering the two halves apart is safe.
write_body_with_tag :: proc(
	b: ^strings.Builder,
	body: []token.Token,
	tag, tag_col: int,
	src: string,
) {
	before := render_tokens(body[:tag], src)
	defer delete(before)
	strings.write_string(b, before)

	for _ in strings.builder_len(b^) ..< tag_col {
		strings.write_string(b, " ")
	}

	write_tag(b, body[tag], src)

	if tag + 1 < len(body) {
		after := render_tokens(body[tag+1:], src)
		defer delete(after)
		strings.write_string(b, after)
	}
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
		if tok.kind == .Tag {
			// A tag is rewritten in its canonical spelling: no space around `=`
			// and one space after each `;`.
			write_tag(&b, tok, src)
			continue
		}
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

// write_tag writes the canonical form of a tag: the pairs with no space around
// their `=`, separated by "; ". The scanner already validated the shape, so a
// lexeme it rejects is written back untouched rather than mangled.
write_tag :: proc(b: ^strings.Builder, tok: token.Token, src: string) {
	lex := token.lexeme(tok, src)
	pairs, ok := token.parse_tag(lex[1:len(lex) - 1])
	defer delete(pairs)
	if !ok {
		strings.write_string(b, lex)
		return
	}
	token.write_tag(b, pairs[:])
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