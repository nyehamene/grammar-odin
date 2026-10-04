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

	// tag_col[line] is the column the tag of that line starts in, or -1 when the
	// line holds no tag or its rule has fewer than two tags to line up (rule 8).
	tag_col := make([dynamic]int, n_lines)
	defer delete(tag_col)
	compute_tag_columns(kinds[:], groups[:], src, align[:], tag_col[:])

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
	// Rule 6: align names to max name width, and align the last parameter of each
	// header in the group to the same column. Columns are measured from the end
	// of a parameter list, so a rule that declares fewer parameters still puts
	// its last one under the last one of its neighbours, and each earlier
	// parameter is right aligned in a cell as wide as the widest parameter in
	// that column.
	name_w := 0
	max_params := 0

	// First pass: name width, and the width of each parameter column.
	for i in start ..< end {
		if kinds[i] != .Header do continue
		lhs := header_tokens(groups[i][:])
		if len(lhs) == 0 do continue
		name_w = max(name_w, len(token.lexeme(lhs[0], src)))
		max_params = max(max_params, len(lhs) - 1)
	}
	col_w := make([dynamic]int, max_params)
	defer delete(col_w)
	for i in start ..< end {
		if kinds[i] != .Header do continue
		lhs := header_tokens(groups[i][:])
		for r in 0 ..< len(lhs) - 1 {
			w := len(token.lexeme(lhs[len(lhs) - 1 - r], src))
			col_w[r] = max(col_w[r], w)
		}
	}

	// Second pass: render each header lhs
	for i in start ..< end {
		if kinds[i] != .Header do continue
		header_lhs[i] = pad_header_new(header_tokens(groups[i][:]), src, name_w, col_w[:])
	}

	// Compute group alignment column for =, |, ; etc (max width of rendered lhs + 1)
	col_sep := 0
	for i in start ..< end {
		if kinds[i] != .Header do continue
		if len(header_lhs[i]) > col_sep {
			col_sep = len(header_lhs[i])
		}
	}

	for j in start ..< end {
		align[j] = col_sep + 1
	}
}

// header_tokens returns the tokens before the `=` of a header line, which is its
// left hand side: a rule name followed by the parameters it declares. The result
// aliases the line and must not be freed.
header_tokens :: proc(line: []token.Token) -> []token.Token {
	return line[:first_equal(line)]
}

// pad_header_new renders lhs, the name followed by the parameters it declares.
// Names are padded to name_w. col_w[r] is the width of the parameter column r
// counted back from the last parameter, so every header in the group writes its
// last parameter in the same column and each earlier one right aligned in a cell
// wide enough for the widest parameter of that column.
pad_header_new :: proc(lhs: []token.Token, src: string, name_w: int, col_w: []int) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	write_padded(&b, token.lexeme(lhs[0], src), name_w)
	params := len(lhs) - 1
	if params <= 0 {
		return strings.clone(strings.to_string(b))
	}

	// The last parameter of every header of the group starts in the same column,
	// and each earlier parameter column sits to the left of it, one space off
	// the column on its right. col_w spans the widest parameter list in the
	// group, so a header that declares fewer parameters still reaches the shared
	// last column.
	last_col := name_w + 1
	for r in 1 ..< len(col_w) {
		last_col += col_w[r] + 1
	}

	// starts[r] is the left edge of the cell of the parameter r counted back
	// from the end of the list.
	starts := make([dynamic]int, params)
	defer delete(starts)
	starts[0] = last_col
	for r in 1 ..< params {
		starts[r] = starts[r - 1] - 1 - col_w[r]
	}

	for j in 0 ..< params {
		r := params - 1 - j
		param := token.lexeme(lhs[j + 1], src)
		target := starts[r] + col_w[r] - len(param)
		for _ in strings.builder_len(b) ..< target {
			strings.write_string(&b, " ")
		}
		strings.write_string(&b, param)
	}
	return strings.clone(strings.to_string(b))
}

// write_padded writes s followed by enough spaces to fill width columns.
write_padded :: proc(b: ^strings.Builder, s: string, width: int) {
	strings.write_string(b, s)
	for _ in len(s) ..< width {
		strings.write_string(b, " ")
	}
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
			widest = max(widest, tag_prefix_width(kinds[i], groups[i][:], tag, src, align[i]))
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
	col: int,
) -> int {
	// A continuation line is written one column past the separator column (rule 5),
	// and a header adds the `=` and the space after it.
	head := col
	start := 0
	switch kind {
	case .Header:
		head = col + 2
		start = first_equal(line) + 1
	case .Body:
		head = col + 2
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
// tag starts in, or -1 to leave the tag where the tokens put it (rule 8).
render_line :: proc(
	line: []token.Token,
	kind: Line_Kind,
	col: int,
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
			return pad_and_render_with_tag(line, col, tag, tag_col, src)
		}
		return pad_and_render(line, col, src)

	case .Body:
		// Rule 5: a continuation line carries no leading `|`, so it is indented
		// one column past the separator column. That makes it read as a
		// continuation of the alternative above it instead of as a sibling of the
		// `|` lines.
		if tag := first_tag(line); tag >= 0 && tag_col >= 0 {
			return pad_and_render_with_tag(line, col + 2, tag, tag_col, src)
		}
		return pad_and_render(line, col + 2, src)

	case .Lone_Semicolon:
		// The terminator lands on the alignment column and anything trailing it,
		// a comment in practice, renders after it.
		return pad_and_render(line, col, src)

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