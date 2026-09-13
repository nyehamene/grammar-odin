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

// format_text for a source string, or nothing when it fails.
format_ok :: proc(t: ^testing.T, src: string) -> string {
	errbuf: bytes.Buffer
	bytes.buffer_init(&errbuf, {})
	defer bytes.buffer_destroy(&errbuf)

	text, ok := format_text(src, "<test>", bytes.buffer_to_stream(&errbuf))
	testing.expect(t, ok, "format_text should succeed")
	testing.expect(t, len(bytes.buffer_to_bytes(&errbuf)) == 0, "no errors expected")
	return text
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
test_rule1_rule_grouping :: proc(t: ^testing.T) {
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

@(test)
test_rule5_blank_line_collapse :: proc(t: ^testing.T) {
	src := "foo = \"one\";\n\n\n\nbar = \"bar\";\n"
	want := "foo = \"one\";\n\nbar = \"bar\";\n"
	check_format(t, src, want)

	// a single blank line is preserved, not removed
	check_format(t, "a = \"a\";\n\nb = \"b\";\n", "a = \"a\";\n\nb = \"b\";\n")
}

@(test)
test_combined_rule1_and_rule4 :: proc(t: ^testing.T) {
	src := "x = \"one\";\nxxxx = \"one\"\n  | \"two\"\n  | \"three\"\n  ;\nxx = \"two\";\n"
	want := "x    = \"one\";\nxxxx = \"one\"\n     | \"two\"\n     | \"three\"\n     ;\nxx   = \"two\";\n"
	check_format(t, src, want)
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
	src := "doc = @import(\"document.grammar\");\nreq = @require(\"lib\");\nbase = a.b.c;\n"
	want := "doc  = @import(\"document.grammar\");\nreq  = @require(\"lib\");\nbase = a.b.c;\n"
	check_format(t, src, want)
}

@(test)
test_rule_call_tight_but_group_spaced :: proc(t: ^testing.T) {
	src := "stmt = <Block stmt>;\nvar = Ident ( a | b );\n"
	want := "stmt = <Block stmt>;\nvar  = Ident ( a | b );\n"
	check_format(t, src, want)
}

@(test)
test_leading_and_trailing_single_blank_preserved :: proc(t: ^testing.T) {
	// a single leading or trailing blank line must be kept (golden rule)
	check_format(t, "\na = \"a\";\n", "\na = \"a\";\n")
	check_format(t, "a = \"a\";\n\n", "a = \"a\";\n\n")

	// runs collapse to one blank line at both ends
	check_format(t, "\n\n\na = \"a\";\n", "\na = \"a\";\n")
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
	}
	for src_ in inputs {
		once := format_ok(t, src_)
		defer delete(once)
		twice := format_ok(t, once)
		defer delete(twice)
		testing.expect(t, once == twice, "formatting must be idempotent")
	}
}

@(test)
test_error_reported_and_source_first :: proc(t: ^testing.T) {
	// Unbalanced group: the parser rejects it, so no output is produced.
	src := "ok = \"x\";\nbad = (\"a\" \"b\";\n"
	errbuf: bytes.Buffer
	bytes.buffer_init(&errbuf, {})
	defer bytes.buffer_destroy(&errbuf)

	text, ok := format_text(src, "demo.grammar", bytes.buffer_to_stream(&errbuf))
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

@(test)
test_run_invalid_args :: proc(t: ^testing.T) {
	stdout, stderr: bytes.Buffer
	bytes.buffer_init(&stdout, {})
	bytes.buffer_init(&stderr, {})
	defer bytes.buffer_destroy(&stdout)
	defer bytes.buffer_destroy(&stderr)

	code := run({"--unknown"}, stdin_unused(), bytes.buffer_to_stream(&stdout), bytes.buffer_to_stream(&stderr))
	testing.expect(t, code == 1, "unknown flag must fail")
	err := string(bytes.buffer_to_bytes(&stderr))
	testing.expect(t, strings.contains(err, "invalid arguments"), "expected invalid arguments")

	// --stdout without a path is invalid
	code = run({"--stdout"}, stdin_unused(), bytes.buffer_to_stream(&stdout), bytes.buffer_to_stream(&stderr))
	testing.expect(t, code == 1, "--stdout without a path must fail")
}

@(test)
test_run_no_path :: proc(t: ^testing.T) {
	stdout, stderr: bytes.Buffer
	bytes.buffer_init(&stdout, {})
	bytes.buffer_init(&stderr, {})
	defer bytes.buffer_destroy(&stdout)
	defer bytes.buffer_destroy(&stderr)

	code := run({}, stdin_unused(), bytes.buffer_to_stream(&stdout), bytes.buffer_to_stream(&stderr))
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
	testing.expect(t, string(a_src) == "x = \"one\";\n", "in-place file should be unchanged when already formatted")
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