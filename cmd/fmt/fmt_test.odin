package fmtcmd

import "core:bytes"
import "core:io"
import "core:os"
import "core:strings"
import "core:testing"

// stdin_unused returns an empty reader for tests that only write to disk.
stdin_unused :: proc() -> io.Stream {
	buf: bytes.Buffer
	bytes.buffer_init(&buf, {})
	return bytes.buffer_to_stream(&buf)
}

// stdin_from returns a reader over src.
stdin_from :: proc(src: string) -> io.Stream {
	r := new(strings.Reader, context.temp_allocator)
	return strings.to_reader(r, src)
}

// Format_Text for a source string, or nothing when it fails.
format_ok :: proc(t: ^testing.T, src: string) -> string {
	errbuf: bytes.Buffer
	bytes.buffer_init(&errbuf, {})
	defer bytes.buffer_destroy(&errbuf)

	text, ok := Format_Text(src, "<test>", bytes.buffer_to_stream(&errbuf))
	testing.expect(t, ok, "Format_Text should succeed")
	testing.expect(t, len(bytes.buffer_to_bytes(&errbuf)) == 0, "no errors expected")
	return text
}

// format_ok_sep is format_ok with an explicit --separator value.
format_ok_sep :: proc(t: ^testing.T, src: string, separator: int) -> string {
	errbuf: bytes.Buffer
	bytes.buffer_init(&errbuf, {})
	defer bytes.buffer_destroy(&errbuf)

	text, ok := Format_Text(src, "<test>", bytes.buffer_to_stream(&errbuf), separator)
	testing.expect(t, ok, "Format_Text should succeed")
	testing.expect(t, len(bytes.buffer_to_bytes(&errbuf)) == 0, "no errors expected")
	return text
}

// check_format_sep asserts that src formats to want at the given separator.
check_format_sep :: proc(t: ^testing.T, src, want: string, separator: int) {
	got := format_ok_sep(t, src, separator)
	defer delete(got)
	testing.expect(t, got == want, "formatted output mismatch")
	if got != want {
		testing.expectf(t, false, "separator %d\ngot:\n%s\nwant:\n%s", separator, got, want)
	}
}

check_format :: proc(t: ^testing.T, src, want: string) {
	got := format_ok(t, src)
	defer delete(got)
	testing.expect(t, got == want, "formatted output mismatch")
	if got != want {
		testing.expectf(t, false, "got:\n%s\nwant:\n%s", got, want)
	}
}

// Per the doc's own examples, the value separator `=` of a rule block lands one
// column past the widest rule name, so it is always preceded by a space.

@(test)
test_rule1_adjacent_rules_share_a_group :: proc(t: ^testing.T) {
	src := "a = \"a\";\nbar = \"bar\";\n\nb = \"a\";\nname = \"name\";\n"
	want := "a   = \"a\";\nbar = \"bar\";\n\nb    = \"a\";\nname = \"name\";\n"
	check_format(t, src, want)
}

@(test)
test_rule2_grouping_symbols :: proc(t: ^testing.T) {
	src := "one = (foo);\ntwo = [bar];\nxxx = {baz};\n"
	want := "one = ( foo );\ntwo = [ bar ];\nxxx = { baz };\n"
	check_format(t, src, want)
}

@(test)
test_rule3_alternative_spacing :: proc(t: ^testing.T) {
	check_format(t, "foo = a|b;\n", "foo = a | b;\n")
}

@(test)
test_rule4_vertical_alignment :: proc(t: ^testing.T) {
	src := "choice = one\n   | two\n   | three\n   ;\n"
	want := "choice = one\n       | two\n       | three\n       ;\n"
	check_format(t, src, want)
}

// Rule 5: a continuation line carries no leading `|`, so it is indented one
// column past the separator column. Without this it would sit flush with the
// `|` lines and read as a sibling alternative.
@(test)
test_rule5_continuation_indent :: proc(t: ^testing.T) {
	src := "choice = one\n   other\n   | two\n   | three ;\n"
	want := "choice = one\n         other\n       | two\n       | three;\n"
	check_format(t, src, want)
}

// Rule 1: only a run of at least `--separator` blank lines ends a group, so with
// 2 the single blank between `a` and `bar` leaves them in one group while the
// double blank before `b` starts a new one.
@(test)
test_rule1_separator_threshold :: proc(t: ^testing.T) {
	src := "a = \"a\";\n\nbar = \"bar\";\n\n\nb = \"a\";\nname = \"name\";\n"
	want := "a   = \"a\";\n\nbar = \"bar\";\n\n\nb    = \"a\";\nname = \"name\";\n"
	check_format_sep(t, src, want, 2)

	// At the default of 1 the single blank does split the groups.
	check_format(t, src, "a = \"a\";\n\nbar = \"bar\";\n\n\nb    = \"a\";\nname = \"name\";\n")
}

// A boundary run longer than the threshold is a group boundary and is kept at
// its original length rather than being trimmed down to `--separator`.
@(test)
test_rule1_boundary_longer_than_separator_preserved :: proc(t: ^testing.T) {
	src := "a = \"a\";\n\n\n\n\nb = \"b\";\n"
	check_format_sep(t, src, src, 2)
	check_format_sep(t, src, src, 1)
}

// Blank lines are reproduced as written, including runs longer than the
// separator threshold, so this source is already formatted.
@(test)
test_blank_lines_preserved :: proc(t: ^testing.T) {
	src := "foo = \"one\";\n\n\n\nbar = \"bar\";\n"
	check_format(t, src, src)

	check_format(t, "a = \"a\";\n\nb = \"b\";\n", "a = \"a\";\n\nb = \"b\";\n")
}

// Rule 6: every rule of a group is written to the width of the widest left hand side
// among them, with the gap after the name, so the value separator of each lands on one
// column. The parameters of a rule are not spaced out among themselves to line up with
// those of a neighbour.
@(test)
test_rule6_param_alignment :: proc(t: ^testing.T) {
	src := "foo x y = x y;\nf x = x;\n\nbar xx y = xx y;\nb x y = x y;\n"
	want := "foo x y = x y;\nf     x = x;\n\nbar xx y = xx y;\nb    x y = x y;\n"
	check_format(t, src, want)

	// A rule with no parameters still has its name aligned, and a rule with more
	// parameters than its neighbour widens the column for the whole group.
	src2 := "a x = a;\nbb y z = b;\n"
	want2 := "a    x = a;\nbb y z = b;\n"
	check_format(t, src2, want2)

	// A single rule in a group pads nothing, so it comes back unchanged.
	check_format(t, "solo x y = x;\n", "solo x y = x;\n")
}

// Rule 6 is scoped by the group, so a blank line at the default threshold ends
// the alignment just like it ends the value separator column.
@(test)
test_rule6_respects_group_boundary :: proc(t: ^testing.T) {
	src := "foo x y = x y;\n\nbar x = x;\n"
	// The blank ends the group, so `bar` aligns against itself alone.
	check_format(t, src, src)

	// With a threshold of 2 the single blank is interior, so the two rules share
	// one group and `bar` pads its missing second parameter out to match `foo`.
	check_format_sep(t, src, "foo x y = x y;\n\nbar   x = x;\n", 2)
}

// The example rule 6 of implementation/08-fmt.md gives, so that the doc and the
// formatter cannot drift apart. It pins rules 1, 2 and 6 at once: a blank line ends the
// first group, the second is written to the width of the widest of its four rules, and
// the grouping symbols inside a body are spaced.
@(test)
test_rule6_matches_the_doc_example :: proc(t: ^testing.T) {
	src :=
		"foo x y = x y;\n" +
		"f x = x;\n" +
		"\n" +
		"bar xx y = xx y;\n" +
		"b x y = x y;\n" +
		"group open close sep x = open x { sep x} [ sep ] close;\n" +
		"group open close sep x y = open [ x { sep x} sep ] y { sep y } close;\n"
	want :=
		"foo x y = x y;\n" +
		"f     x = x;\n" +
		"\n" +
		"bar                 xx y = xx y;\n" +
		"b                    x y = x y;\n" +
		"group   open close sep x = open x { sep x } [ sep ] close;\n" +
		"group open close sep x y = open [ x { sep x } sep ] y { sep y } close;\n"
	check_format(t, src, want)
}

// The rule with fewer parameters need not be the narrower one, and a left hand side is
// padded whole rather than by lining its parameters up in columns of their own: here
// `foo x y` is written to the width of `f a b c d`, and neither is spaced internally.
@(test)
test_rule6_pads_whole_left_hand_sides :: proc(t: ^testing.T) {
	check_format(t, "foo x y = x y;\nf a b c d = a;\n", "foo   x y = x y;\nf a b c d = a;\n")
}

@(test)
test_combined_rule1_and_rule4 :: proc(t: ^testing.T) {
	src := "x = \"one\";\nxxxx = \"one\"\n  | \"two\"\n  | \"three\"\n  ;\nxx = \"two\";\n"
	want := "x    = \"one\";\nxxxx = \"one\"\n     | \"two\"\n     | \"three\"\n     ;\nxx   = \"two\";\n"
	check_format(t, src, want)
}

// An external only needs its "__" prefix to scan, but the canonical spelling
// closes it with another "__", so the formatter supplies one when missing.
@(test)
test_external_gets_trailing_delimiter :: proc(t: ^testing.T) {
	check_format(t, "e = __name;\n", "e = __name__;\n")
	check_format(t, "e = __bar_name;\n", "e = __bar_name__;\n")

	// already closed, or containing a run of its own: left alone
	check_format(t, "e = __name__;\n", "e = __name__;\n")
	check_format(t, "e = __a__b__;\n", "e = __a__b__;\n")

	// several externals on one line, each closed independently
	check_format(t, "e = __one __two;\n", "e = __one__ __two__;\n")
}

@(test)
test_doc_example_var_and_ast :: proc(t: ^testing.T) {
	src := "/// @var\ndocument = @import(\"document.grammar\");\ncomponent = @import(\"component.grammar\");\n\n/// @ast\nSource = DocumentNamespace | ComponentNamespace;\nDocumentNamespace = document;\nComponentNamespace = component;\n"
	want := "/// @var\ndocument  = @import(\"document.grammar\");\ncomponent = @import(\"component.grammar\");\n\n/// @ast\nSource             = DocumentNamespace | ComponentNamespace;\nDocumentNamespace  = document;\nComponentNamespace = component;\n"
	check_format(t, src, want)
}

// The golden rule: the formatter must never add or remove newlines. A `;` that
// already sits on its own line is aligned with the `|` column; a `;` sharing a
// line with its alternative is left in place.
@(test)
test_golden_rule_inline_semicolon_not_moved :: proc(t: ^testing.T) {
	src := "x = \"one\";\nxxx = \"one\"\n  | \"two\"\n  | \"three\";\nxx = \"two\";\n"
	want := "x   = \"one\";\nxxx = \"one\"\n    | \"two\"\n    | \"three\";\nxx  = \"two\";\n"
	check_format(t, src, want)
}

@(test)
test_golden_rule_newlines_conserved :: proc(t: ^testing.T) {
	inputs := []string {
		"a = \"a\";\nbar = \"bar\";\n",
		"choice = one\n   | two\n   ;\n",
		"foo = ( a | b ) [ c ] { d };\n",
		"doc = @import(\"x.grammar\");\n",
		"a = \"a\";",
		"a = \"a\";\n",
		"a = \"a\";\n\nb = \"b\";\n",
		"// only a comment\n",
		"\na = \"a\";\n",
	}
	for sample in inputs {
		got := format_ok(t, sample)
		testing.expect(
			t,
			strings.count(got, "\n") == strings.count(sample, "\n"),
			"newline count must be conserved when there are no blank runs",
		)
		if strings.count(got, "\n") != strings.count(sample, "\n") {
			testing.expectf(t, false, "source: %q -> %q", sample, got)
		}
		delete(got)
	}
}

@(test)
test_directive_call_and_member_stay_tight :: proc(t: ^testing.T) {
	src := "doc = @import(\"document.grammar\");\nreq = @require(\"lib\");\nbase = a.b;\n"
	want := "doc  = @import(\"document.grammar\");\nreq  = @require(\"lib\");\nbase = a.b;\n"
	check_format(t, src, want)
}

@(test)
test_rule_call_tight_but_group_spaced :: proc(t: ^testing.T) {
	src := "stmt = <Block stmt>;\nvar = Ident ( a | b );\n"
	want := "stmt = <Block stmt>;\nvar  = Ident ( a | b );\n"
	check_format(t, src, want)
}

// Leading blank lines are kept exactly as written, while a run at the end of
// the file collapses to a single blank line (golden rule).
@(test)
test_leading_blanks_kept_and_trailing_collapsed :: proc(t: ^testing.T) {
	check_format(t, "\na = \"a\";\n", "\na = \"a\";\n")
	check_format(t, "a = \"a\";\n\n", "a = \"a\";\n\n")

	// leading runs survive verbatim, trailing runs collapse to one
	check_format(t, "\n\n\na = \"a\";\n", "\n\n\na = \"a\";\n")
	check_format(t, "a = \"a\";\n\n\n\n", "a = \"a\";\n\n")
}

@(test)
test_comment_lines_kept_verbatim :: proc(t: ^testing.T) {
	src := "// a header comment\nx = \"x\";\n   // indented\n"
	want := "// a header comment\nx = \"x\";\n   // indented\n"
	check_format(t, src, want)

	src2 := "x = \"x\"; // trailing\nbar = ( a | b );\n"
	want2 := "x   = \"x\"; // trailing\nbar = ( a | b );\n"
	check_format(t, src2, want2)
}

// A comment inside a rule body is trivia to the parser, so the formatter must
// accept it and keep it on the line it was written on, aligned like any other
// trailing comment.
@(test)
test_comments_inside_rule_body :: proc(t: ^testing.T) {
	src := "rule1 = a // comment\n      | b // comment\n      ;\n"
	want := "rule1 = a // comment\n      | b // comment\n      ;\n"
	check_format(t, src, want)

	// A trailing comment does not turn the rule terminator into a continuation
	// line: `;`, `|` and `=` stay on one column (rules 4 and 5).
	src2 := "choice = one // one\n   two // two\n   | three // three\n   ; // done\n"
	want2 := "choice = one // one\n         two // two\n       | three // three\n       ; // done\n"
	check_format(t, src2, want2)

	// A comment inside a grouping symbol or a call argument list is kept too.
	// Rule 9 scopes the continuation indent to the construct, so the second
	// lines sit two past the `(` and the `<`, not at the rule's alignment column.
	src3 := "g = ( a // one\n   b );\nq = <f a // two\n   b>;\n"
	want3 := "g = ( a // one\n      b );\nq = <f a // two\n      b>;\n"
	check_format(t, src3, want3)
}

// Rule 9 scopes rules 4 and 5 inside a group, so a continuation of a group's body
// indents two past its opening `(`, a `|` line aligns with the opening, and a lone
// `)` lands on it. Matches the group examples of implementation/08-fmt.md.
@(test)
test_rule9_group :: proc(t: ^testing.T) {
	src :=
		"foo0 = ( a b c );\n" +
		"\n" +
		"foo1 = ( a b\n" +
		"   c );\n" +
		"\n" +
		"foo2 = ( a b\n" +
		"   c\n" +
		"   );\n" +
		"\n" +
		"foo3 = ( a b\n" +
		"   | c );\n" +
		"\n" +
		"foo4 = ( a b\n" +
		"   | c\n" +
		"   );\n"
	want :=
		"foo0 = ( a b c );\n" +
		"\n" +
		"foo1 = ( a b\n" +
		"         c );\n" +
		"\n" +
		"foo2 = ( a b\n" +
		"         c\n" +
		"       );\n" +
		"\n" +
		"foo3 = ( a b\n" +
		"       | c );\n" +
		"\n" +
		"foo4 = ( a b\n" +
		"       | c\n" +
		"       );\n"
	check_format(t, src, want)
}

// The same layout applies inside an optional: continuation two past its opening
// `[`, `|` and a lone `]` on it (rule 9).
@(test)
test_rule9_optional :: proc(t: ^testing.T) {
	src :=
		"foo0 = [ a b c ];\n" +
		"\n" +
		"foo1 = [ a b\n" +
		"   c ];\n" +
		"\n" +
		"foo2 = [ a b\n" +
		"   c\n" +
		"   ];\n" +
		"\n" +
		"foo3 = [ a b\n" +
		"   | c ];\n" +
		"\n" +
		"foo4 = [ a b\n" +
		"   | c\n" +
		"   ];\n"
	want :=
		"foo0 = [ a b c ];\n" +
		"\n" +
		"foo1 = [ a b\n" +
		"         c ];\n" +
		"\n" +
		"foo2 = [ a b\n" +
		"         c\n" +
		"       ];\n" +
		"\n" +
		"foo3 = [ a b\n" +
		"       | c ];\n" +
		"\n" +
		"foo4 = [ a b\n" +
		"       | c\n" +
		"       ];\n"
	check_format(t, src, want)
}

// And inside a repetition: continuation two past its opening `{`, `|` and a lone
// `}` on it (rule 9).
@(test)
test_rule9_repetition :: proc(t: ^testing.T) {
	src :=
		"foo0 = { a b c };\n" +
		"\n" +
		"foo1 = { a b\n" +
		"   c };\n" +
		"\n" +
		"foo2 = { a b\n" +
		"   c\n" +
		"   };\n" +
		"\n" +
		"foo3 = { a b\n" +
		"   | c };\n" +
		"\n" +
		"foo4 = { a b\n" +
		"   | c\n" +
		"   };\n"
	want :=
		"foo0 = { a b c };\n" +
		"\n" +
		"foo1 = { a b\n" +
		"         c };\n" +
		"\n" +
		"foo2 = { a b\n" +
		"         c\n" +
		"       };\n" +
		"\n" +
		"foo3 = { a b\n" +
		"       | c };\n" +
		"\n" +
		"foo4 = { a b\n" +
		"       | c\n" +
		"       };\n"
	check_format(t, src, want)
}

// A call takes the same rules with no real `|`: its arguments continue two past
// the `<`, whether or not the callee shares the line, and a lone `>` lands on the
// `<`. Matches the call examples of implementation/08-fmt.md.
@(test)
test_rule9_call :: proc(t: ^testing.T) {
	src :=
		"foo0 = <foo b c>;\n" +
		"\n" +
		"foo1 = <foo b\n" +
		"   c>;\n" +
		"\n" +
		"foo2 = <foo b\n" +
		"   c\n" +
		"   >;\n" +
		"\n" +
		"foo3 = <foo\n" +
		"   b\n" +
		"   c>;\n" +
		"\n" +
		"foo4 = <foo\n" +
		"   b\n" +
		"   c\n" +
		"   >;\n"
	want :=
		"foo0 = <foo b c>;\n" +
		"\n" +
		"foo1 = <foo b\n" +
		"         c>;\n" +
		"\n" +
		"foo2 = <foo b\n" +
		"         c\n" +
		"       >;\n" +
		"\n" +
		"foo3 = <foo\n" +
		"         b\n" +
		"         c>;\n" +
		"\n" +
		"foo4 = <foo\n" +
		"         b\n" +
		"         c\n" +
		"       >;\n"
	check_format(t, src, want)
}

// Rule 9 nests: the innermost open construct owns the column, so a call inside a
// group indents from the call's `<` and a group's `|` from the group's `(`, while
// a call opened on a continuation line indents from its own `<`.
@(test)
test_rule9_nested_constructs :: proc(t: ^testing.T) {
	src :=
		"wrap = ( <foo a\n" +
		"b>\n" +
		"| c );\n" +
		"deep = a\n" +
		"<bar x\n" +
		"y>\n" +
		"z;\n"
	want :=
		"wrap = ( <foo a\n" +
		"           b>\n" +
		"       | c );\n" +
		"deep = a\n" +
		"       <bar x\n" +
		"         y>\n" +
		"       z;\n"
	check_format(t, src, want)
}

// Rule 6 pads the left hand side before rule 9 measures the opening delimiter, so
// a construct opened in a group whose column another rule widened indents from the
// *formatted* column, not the one the source wrote.
@(test)
test_rule9_opens_at_the_formatted_column :: proc(t: ^testing.T) {
	src := "wide rule x = ( a\n   b );\nshort = ( c\n   d );\n"
	want := "wide rule x = ( a\n                b );\nshort       = ( c\n                d );\n"
	check_format(t, src, want)
}

// A trailing comment changes nothing: a `|` line inside a group and a lone closing
// line still land on the construct's opening column (rules 4 and 9).
@(test)
test_rule9_comment_inside_a_construct :: proc(t: ^testing.T) {
	src := "foo = ( a\n   | b // why\n   );\n"
	want := "foo = ( a\n      | b // why\n      );\n"
	check_format(t, src, want)
}

@(test)
test_empty_input :: proc(t: ^testing.T) {
	check_format(t, "", "")
}

@(test)
test_keywords_and_numbers_verbatim :: proc(t: ^testing.T) {
	src := "number = number_dec|number_hex|number_bin;\n"
	want := "number = number_dec | number_hex | number_bin;\n"
	check_format(t, src, want)
}

@(test)
test_idempotent :: proc(t: ^testing.T) {
	inputs := []string {
		"x = \"one\";\nxxxx = \"one\"\n  | \"two\"\n  | \"three\";\nxx = \"two\";\n",
		"/// @var\ndocument = @import(\"document.grammar\");\ncomponent = @import(\"component.grammar\");\n\n/// @ast\nSource = DocumentNamespace | ComponentNamespace;\n",
		"choice = one\n   | two\n   | three\n   ;\n",
		"rule1 = a // comment\n      | b // comment\n      ;\n",
		"choice = one // one\n   | two // two\n   ; // done\n",
		"foo x y = x y;\nf x = x;\n\nbar xx y = xx y;\nb x y = x y;\n",
		"a = \"a\";\nfoo = a `name=\"a\"; other=\"b\"`;\nbar = a b `n = \"1\"`;\nbaz = ( a ) `n=\"2\"`;\n",
		"foo = a b `n=\"1\"`\n  | xxxxxx `n=\"2\"`\n  | x `n=\"3\"`\n  ;\n",
		"foo = a\n  b `n=\"1\"`\n  | c `n=\"2\"`\n  ;\n",
		"foo1 = ( a b\n  c );\nfoo2 = [ a b\n  | c ];\nfoo3 = { a b\n  c\n};\nfoo4 = <foo\nb\nc>;\n",
	}
	for src_ in inputs {
		once := format_ok(t, src_)
		defer delete(once)
		twice := format_ok(t, once)
		defer delete(twice)
		testing.expect(t, once == twice, "formatting must be idempotent")
	}
}

// A tag is rewritten in one canonical spelling: no space around `=`, one space
// after each `;`, and the string values keep their quotes.
@(test)
test_tag_is_written_canonically :: proc(t: ^testing.T) {
	check_format(t, "foo = x `name = \"a\"`;\n", "foo = x `name=\"a\"`;\n")
	check_format(t, "foo = x `name=\"a\";other=\"b\"`;\n", "foo = x `name=\"a\"; other=\"b\"`;\n")
	check_format(
		t,
		"foo = x `  name=\"a\"  ;  other  =  \"b\"  `;\n",
		"foo = x `name=\"a\"; other=\"b\"`;\n",
	)
}

// The value is a string literal, so a `;` or a quote inside it is not a
// separator and survives untouched.
@(test)
test_tag_value_keeps_separators_inside_it :: proc(t: ^testing.T) {
	check_format(
		t,
		"foo = x `note=\"a; b\"; other=\"q\\\"r\"`;\n",
		"foo = x `note=\"a; b\"; other=\"q\\\"r\"`;\n",
	)
}

@(test)
test_tag_on_a_group_is_written_outside_it :: proc(t: ^testing.T) {
	check_format(t, "foo = ( x ) `name=\"a\"`;\n", "foo = ( x ) `name=\"a\"`;\n")
	check_format(t, "foo = [ x ] { y } `name=\"a\"`;\n", "foo = [ x ] { y } `name=\"a\"`;\n")
}

// The tags of one rule share a column, so that a production arranged over several
// lines has its tags read down the page (rule 8).
@(test)
test_tags_align_when_alternatives_align :: proc(t: ^testing.T) {
	check_format(
		t,
		"foo = a b `n=\"1\"`\n  | xxxxxx `n=\"2\"`\n  | x `n=\"3\"`\n  ;\n",
		"foo = a b    `n=\"1\"`\n    | xxxxxx `n=\"2\"`\n    | x      `n=\"3\"`\n    ;\n",
	)
	check_format(
		t,
		"foo = a `n=\"1\"`\n  | bbb `n=\"2\"`\n  ;\n",
		"foo = a   `n=\"1\"`\n    | bbb `n=\"2\"`\n    ;\n",
	)
}

// A tag on a group is written outside it, and the two tags still line up.
@(test)
test_tags_align_across_groups :: proc(t: ^testing.T) {
	check_format(
		t,
		"foo = ( a ) `n=\"1\"`\n  | ( b ) `n=\"2\"`\n  ;\n",
		"foo = ( a ) `n=\"1\"`\n    | ( b ) `n=\"2\"`\n    ;\n",
	)
}

// A tag annotates the last element of a production, so it closes the continuation
// line it is written on. It aligns like any other.
@(test)
test_tags_align_on_a_continuation_line :: proc(t: ^testing.T) {
	check_format(
		t,
		"foo = a\n  b `n=\"1\"`\n  | c `n=\"2\"`\n  ;\n",
		"foo = a\n      b `n=\"1\"`\n    | c `n=\"2\"`\n    ;\n",
	)
}

// A rule with a single tag has nothing to line it up against, so it keeps the one
// space the tokens give it rather than being padded away from its production.
@(test)
test_one_tag_is_left_where_it_is :: proc(t: ^testing.T) {
	check_format(t, "foo = a `n=\"1\"`;\n", "foo = a `n=\"1\"`;\n")
	check_format(
		t,
		"foo = a `n=\"1\"`\n  | bbb;\n",
		"foo = a `n=\"1\"`\n    | bbb;\n",
	)
}

// The tags of a rule line up with each other and not with those of its neighbours,
// even when the rules share an alignment group.
@(test)
test_tags_align_per_rule :: proc(t: ^testing.T) {
	check_format(
		t,
		"one = a `n=\"1\"`\n  | bb\n  ;\n\ntwo = c `n=\"3\"`\n  | dd `n=\"4\"`\n  ;\n",
		"one = a `n=\"1\"`\n    | bb\n    ;\n\ntwo = c  `n=\"3\"`\n    | dd `n=\"4\"`\n    ;\n",
	)
	check_format(
		t,
		"one = a `n=\"1\"`\n  | bb `n=\"2\"`\n  ;\ntwo = c `n=\"3\"`\n  | dd `n=\"4\"`\n  ;\n",
		"one = a  `n=\"1\"`\n    | bb `n=\"2\"`\n    ;\ntwo = c  `n=\"3\"`\n    | dd `n=\"4\"`\n    ;\n",
	)
}

@(test)
test_error_reported_and_source_first :: proc(t: ^testing.T) {
	// Unbalanced group: the parser rejects it, so no output is produced.
	src := "ok = \"x\";\nbad = (\"a\" \"b\";\n"
	errbuf: bytes.Buffer
	bytes.buffer_init(&errbuf, {})
	defer bytes.buffer_destroy(&errbuf)

	text, ok := Format_Text(src, "demo.grammar", bytes.buffer_to_stream(&errbuf))
	testing.expect(t, !ok, "format must fail on a syntax error")
	testing.expect(t, text == "", "no output on error")
	err := string(bytes.buffer_to_bytes(&errbuf))
	testing.expect(t, strings.contains(err, "demo.grammar:2:"), "error must carry line info")
	testing.expect(t, strings.contains(err, "expected RParen"), "parser error text expected")
}

@(test)
test_stdin_mode :: proc(t: ^testing.T) {
	stdout, stderr: bytes.Buffer
	bytes.buffer_init(&stdout, {})
	bytes.buffer_init(&stderr, {})
	defer bytes.buffer_destroy(&stdout)
	defer bytes.buffer_destroy(&stderr)

	code := run(
		{"--stdin"},
		stdin_from("a = (foo);\nbar = [baz];\n"),
		bytes.buffer_to_stream(&stdout),
		bytes.buffer_to_stream(&stderr),
	)
	testing.expect(t, code == 0, "stdin formatting should succeed")
	want := "a   = ( foo );\nbar = [ baz ];\n"
	testing.expect(t, string(bytes.buffer_to_bytes(&stdout)) == want, "stdin output mismatch")
	testing.expect(t, len(bytes.buffer_to_bytes(&stderr)) == 0, "no errors on stderr")
}

// `-s`/`--separator` sets the group threshold and combines with `--stdin`.
@(test)
test_separator_flag_with_stdin :: proc(t: ^testing.T) {
	stdout, stderr: bytes.Buffer
	bytes.buffer_init(&stdout, {})
	bytes.buffer_init(&stderr, {})
	defer bytes.buffer_destroy(&stdout)
	defer bytes.buffer_destroy(&stderr)

	// One blank line does not separate the groups at separator 2, so `a` and
	// `bar` are aligned as a pair.
	code := run(
		{"--stdin", "-s", "2"},
		stdin_from("a = \"a\";\n\nbar = \"bar\";\n"),
		bytes.buffer_to_stream(&stdout),
		bytes.buffer_to_stream(&stderr),
	)
	testing.expect(t, code == 0, "stdin formatting should succeed")
	testing.expect(
		t,
		string(bytes.buffer_to_bytes(&stdout)) == "a   = \"a\";\n\nbar = \"bar\";\n",
		"separator output mismatch",
	)
	testing.expect(t, len(bytes.buffer_to_bytes(&stderr)) == 0, "no errors on stderr")
}

// The `--separator=N` form is accepted, and a value below 1 is ignored.
@(test)
test_separator_equals_form_and_clamping :: proc(t: ^testing.T) {
	src := "a = \"a\";\n\n\n\n\nb = \"b\";\n"
	// separator 3 still treats the 4-blank run as a boundary, kept verbatim.
	check_format_sep(t, src, src, 3)

	for sep, i in ([]int{0, -1, -7}) {
		got := format_ok_sep(t, "a = \"a\";\n\nbar = \"bar\";\n", sep)
		testing.expectf(
			t,
			got == "a = \"a\";\n\nbar = \"bar\";\n",
			"separator %d should clamp to 1",
			i,
		)
		delete(got)
	}
}

// Formatting is idempotent at a non-default separator too.
@(test)
test_separator_idempotent :: proc(t: ^testing.T) {
	src := "a = \"a\";\n\nbar = \"bar\";\n\n\nb = \"a\";\nname = \"name\";\n"
	once := format_ok_sep(t, src, 2)
	defer delete(once)
	twice := format_ok_sep(t, once, 2)
	defer delete(twice)
	testing.expect(t, once == twice, "formatting must be idempotent at separator 2")
}

@(test)
test_separator_invalid_values :: proc(t: ^testing.T) {
	cases := [][]string {
		{"--stdin", "-s"},
		{"--stdin", "-s", "abc"},
		{"--stdin", "--separator"},
		{"--stdin", "--separator=xyz"},
	}
	for args, i in cases {
		stdout, stderr: bytes.Buffer
		bytes.buffer_init(&stdout, {})
		bytes.buffer_init(&stderr, {})

		code := run(
			args,
			stdin_unused(),
			bytes.buffer_to_stream(&stdout),
			bytes.buffer_to_stream(&stderr),
		)
		testing.expectf(t, code == 1, "invalid separator must fail (case %d)", i)
		err := string(bytes.buffer_to_bytes(&stderr))
		testing.expectf(
			t,
			strings.contains(err, "invalid arguments"),
			"expected invalid arguments (case %d)",
			i,
		)

		bytes.buffer_destroy(&stdout)
		bytes.buffer_destroy(&stderr)
	}
}

@(test)
test_run_invalid_args :: proc(t: ^testing.T) {
	stdout, stderr: bytes.Buffer
	bytes.buffer_init(&stdout, {})
	bytes.buffer_init(&stderr, {})
	defer bytes.buffer_destroy(&stdout)
	defer bytes.buffer_destroy(&stderr)

	code := run(
		{"--unknown"},
		stdin_unused(),
		bytes.buffer_to_stream(&stdout),
		bytes.buffer_to_stream(&stderr),
	)
	testing.expect(t, code == 1, "unknown flag must fail")
	err := string(bytes.buffer_to_bytes(&stderr))
	testing.expect(t, strings.contains(err, "invalid arguments"), "expected invalid arguments")

	// --stdout without a path is invalid
	code = run(
		{"--stdout"},
		stdin_unused(),
		bytes.buffer_to_stream(&stdout),
		bytes.buffer_to_stream(&stderr),
	)
	testing.expect(t, code == 1, "--stdout without a path must fail")
}

@(test)
test_run_no_path :: proc(t: ^testing.T) {
	stdout, stderr: bytes.Buffer
	bytes.buffer_init(&stdout, {})
	bytes.buffer_init(&stderr, {})
	defer bytes.buffer_destroy(&stdout)
	defer bytes.buffer_destroy(&stderr)

	code := run(
		{},
		stdin_unused(),
		bytes.buffer_to_stream(&stdout),
		bytes.buffer_to_stream(&stderr),
	)
	testing.expect(t, code == 1, "missing PATH must fail")
	err := string(bytes.buffer_to_bytes(&stderr))
	testing.expect(t, strings.contains(err, "requires a PATH"), "expected missing PATH message")
}

@(test)
test_stdout_mode_and_multi_path :: proc(t: ^testing.T) {
	dir := "cmd/fmt/testdata/scratch/stdout_multi"
	os.remove_all(dir)
	os.make_directory_all(dir)
	defer os.remove_all(dir)
	a := strings.concatenate({dir, "/a.grammar"})
	b := strings.concatenate({dir, "/b.grammar"})
	defer delete(a)
	defer delete(b)
	if err := os.write_entire_file(a, "x = \"one\";\n"); err != nil {
		testing.fail_now(t, "failed to write test file")
	}
	if err := os.write_entire_file(b, "gg = \"two\";\n"); err != nil {
		testing.fail_now(t, "failed to write test file")
	}

	stdout, stderr: bytes.Buffer
	bytes.buffer_init(&stdout, {})
	bytes.buffer_init(&stderr, {})
	defer bytes.buffer_destroy(&stdout)
	defer bytes.buffer_destroy(&stderr)

	// a is formatted in place; b is printed to stdout.
	code := run(
		{a, "--stdout", b},
		stdin_unused(),
		bytes.buffer_to_stream(&stdout),
		bytes.buffer_to_stream(&stderr),
	)
	testing.expect(t, code == 0, "formatting should succeed")

	a_src, _ := os.read_entire_file_from_path(a, context.temp_allocator)
	testing.expect(
		t,
		string(a_src) == "x = \"one\";\n",
		"in-place file should be unchanged when already formatted",
	)
	b_src, _ := os.read_entire_file_from_path(b, context.temp_allocator)
	testing.expect(t, string(b_src) == "gg = \"two\";\n", "--stdout must not rewrite the file")

	out := string(bytes.buffer_to_bytes(&stdout))
	testing.expect(t, out == "gg = \"two\";\n", "--stdout output mismatch")
	testing.expect(t, len(bytes.buffer_to_bytes(&stderr)) == 0, "no errors on stderr")
}

@(test)
test_in_place_rewrites_and_error_is_safe :: proc(t: ^testing.T) {
	dir := "cmd/fmt/testdata/scratch/in_place"
	os.remove_all(dir)
	os.make_directory_all(dir)
	defer os.remove_all(dir)

	// A file that needs reformatting is rewritten in place.
	good := strings.concatenate({dir, "/good.grammar"})
	defer delete(good)
	if err := os.write_entire_file(good, "a = \"a\";\nbar = \"bar\";\n"); err != nil {
		testing.fail_now(t, "failed to write test file")
	}

	// A file with a syntax error is left byte-for-byte unchanged.
	bad := strings.concatenate({dir, "/bad.grammar"})
	defer delete(bad)
	bad_src := "ok = \"x\";\nbad = (\"a\" \"b\";\n"
	if err := os.write_entire_file(bad, bad_src); err != nil {
		testing.fail_now(t, "failed to write test file")
	}

	stdout, stderr: bytes.Buffer
	bytes.buffer_init(&stdout, {})
	bytes.buffer_init(&stderr, {})
	defer bytes.buffer_destroy(&stdout)
	defer bytes.buffer_destroy(&stderr)

	code := run(
		{good, bad},
		stdin_unused(),
		bytes.buffer_to_stream(&stdout),
		bytes.buffer_to_stream(&stderr),
	)
	testing.expect(t, code == 1, "run must fail when one file has an error")

	good_src, _ := os.read_entire_file_from_path(good, context.temp_allocator)
	want := "a   = \"a\";\nbar = \"bar\";\n"
	testing.expect(t, string(good_src) == want, "good file should be formatted in place")

	bad_after, _ := os.read_entire_file_from_path(bad, context.temp_allocator)
	testing.expect(t, string(bad_after) == bad_src, "bad file must stay unchanged")

	err := string(bytes.buffer_to_bytes(&stderr))
	testing.expect(t, strings.contains(err, "bad.grammar:2:"), "error must name the file and line")
}

@(test)
test_crlf_and_trailing_newline_preserved :: proc(t: ^testing.T) {
	check_format(t, "a = \"a\";\r\nbar = \"bar\";\r\n", "a   = \"a\";\r\nbar = \"bar\";\r\n")
	check_format(t, "x = \"one\";\ngg = \"two\";", "x  = \"one\";\ngg = \"two\";")
}
