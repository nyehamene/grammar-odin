package printcmd

import "core:bytes"
import "core:io"
import "core:strings"
import "core:testing"

// stdin_unused returns an empty reader for tests that only write output.
stdin_unused :: proc() -> io.Stream {
	buf: bytes.Buffer
	bytes.buffer_init(&buf, {})
	return bytes.buffer_to_stream(&buf)
}

@(test)
test_print_tokens_output :: proc(t: ^testing.T) {
	src := `greeting = "Hello" | "Hi";` + "\n"
	buf: bytes.Buffer
	bytes.buffer_init(&buf, {})
	defer bytes.buffer_destroy(&buf)
	errbuf: bytes.Buffer
	bytes.buffer_init(&errbuf, {})
	defer bytes.buffer_destroy(&errbuf)

	code := print_tokens(src, "<test>", bytes.buffer_to_stream(&buf), bytes.buffer_to_stream(&errbuf))
	testing.expect(t, code == 0, "no errors expected")
	testing.expect(t, len(bytes.buffer_to_bytes(&errbuf)) == 0, "no errors to stderr")

	out := string(bytes.buffer_to_bytes(&buf))
	testing.expect(t, strings.has_prefix(out, "Line:Col"), "header line missing")
	testing.expect(t, strings.contains(out, "KIND"), "KIND column missing")
	testing.expect(t, strings.contains(out, "LEXEME"), "LEXEME column missing")
	testing.expect(t, strings.contains(out, "Ident"), "should contain Ident token")
	testing.expect(t, strings.contains(out, "greeting"), "should contain greeting lexeme")
	testing.expect(t, strings.contains(out, "\"Hello\""), "should contain string literal lexeme")
	testing.expect(t, strings.contains(out, "|"), "should contain pipe token")
	testing.expect(t, strings.contains(out, "--------------------------------------------------"), "separator line missing")
}

@(test)
test_print_ast_output :: proc(t: ^testing.T) {
	src := `greeting = "Hello" | "Hi";` + "\n"
	buf: bytes.Buffer
	bytes.buffer_init(&buf, {})
	defer bytes.buffer_destroy(&buf)
	errbuf: bytes.Buffer
	bytes.buffer_init(&errbuf, {})
	defer bytes.buffer_destroy(&errbuf)

	code := print_ast(src, "<test>", bytes.buffer_to_stream(&buf), bytes.buffer_to_stream(&errbuf))
	testing.expect(t, code == 0, "no errors expected")

	out := string(bytes.buffer_to_bytes(&buf))
	testing.expect(t, strings.has_prefix(out, "File\n"), "should start with File header")
	testing.expect(t, strings.contains(out, "RuleDecl: greeting"), "should print rule name")
	testing.expect(t, strings.contains(out, "TermExpr"), "should contain TermExpr")
	testing.expect(t, strings.contains(out, "AlternativeExpr"), "should contain AlternativeExpr")
	testing.expect(t, strings.contains(out, "StringLit: \"Hello\""), "should contain string literal")
	testing.expect(t, strings.contains(out, "StringLit: \"Hi\""), "should contain second alternative")
}

// A tag annotates a whole production, so the tree nests the sequence under the
// wrapper rather than hanging the tag off the last element.
@(test)
test_print_ast_tagged_sequence :: proc(t: ^testing.T) {
	src := "greeting = hello world `name=\"a\"; other=\"b\"`;\n"
	buf: bytes.Buffer
	bytes.buffer_init(&buf, {})
	defer bytes.buffer_destroy(&buf)
	errbuf: bytes.Buffer
	bytes.buffer_init(&errbuf, {})
	defer bytes.buffer_destroy(&errbuf)

	code := print_ast(src, "<test>", bytes.buffer_to_stream(&buf), bytes.buffer_to_stream(&errbuf))
	testing.expect(t, code == 0, "no errors expected")

	out := string(bytes.buffer_to_bytes(&buf))
	tagged_at := strings.index(out, "TaggedExpr")
	testing.expect(t, tagged_at >= 0, "should print TaggedExpr")
	seq_at := strings.index(out, "SequenceExpr")
	testing.expect(t, seq_at > tagged_at, "the sequence should be nested under the tag")
	testing.expect(t, strings.contains(out, "TagPair: name=\"a\""), "should print the first pair")
	testing.expect(t, strings.contains(out, "TagPair: other=\"b\""), "should print the second pair")

	// The whole sequence is annotated, so no element is wrapped on its own.
	testing.expect(
		t,
		strings.count(out, "TaggedExpr") == 1,
		"a tag should annotate one production",
	)
}

@(test)
test_print_ast_error_partial :: proc(t: ^testing.T) {
	src := "ok = \"x\";\nbad = (\"a\" \"b\";\n"
	buf: bytes.Buffer
	bytes.buffer_init(&buf, {})
	defer bytes.buffer_destroy(&buf)
	errbuf: bytes.Buffer
	bytes.buffer_init(&errbuf, {})
	defer bytes.buffer_destroy(&errbuf)

	code := print_ast(src, "<test>", bytes.buffer_to_stream(&buf), bytes.buffer_to_stream(&errbuf))
	testing.expect(t, code == 1, "should return non-zero on errors")

	// the valid rule before the error is still printed
	out := string(bytes.buffer_to_bytes(&buf))
	testing.expect(t, strings.has_prefix(out, "File\n"), "partial AST should still be printed")
	testing.expect(t, strings.contains(out, "RuleDecl: ok"), "valid rule should be printed")
	testing.expect(t, !strings.contains(out, "RuleDecl: bad"), "bad rule should be dropped")

	// errors on stderr
	err := string(bytes.buffer_to_bytes(&errbuf))
	testing.expect(t, strings.contains(err, "expected RParen"), "missing RParen error")
}

@(test)
test_print_ast_preserves_comments :: proc(t: ^testing.T) {
	src := "// a comment\nx = \"x\";\n"
	buf: bytes.Buffer
	bytes.buffer_init(&buf, {})
	defer bytes.buffer_destroy(&buf)
	errbuf: bytes.Buffer
	bytes.buffer_init(&errbuf, {})
	defer bytes.buffer_destroy(&errbuf)

	code := print_ast(src, "<test>", bytes.buffer_to_stream(&buf), bytes.buffer_to_stream(&errbuf))
	testing.expect(t, code == 0, "no errors expected")
	out := string(bytes.buffer_to_bytes(&buf))
	testing.expect(t, strings.contains(out, "// a comment"), "comment text should appear in AST output")
}

@(test)
test_run_default_flag_is_ast :: proc(t: ^testing.T) {
	stdout, stderr: bytes.Buffer
	bytes.buffer_init(&stdout, {})
	bytes.buffer_init(&stderr, {})
	defer bytes.buffer_destroy(&stdout)
	defer bytes.buffer_destroy(&stderr)

	// no -t or -a → should default to AST
	code := run({"cmd/print/testdata/hello.grammar"}, stdin_unused(), bytes.buffer_to_stream(&stdout), bytes.buffer_to_stream(&stderr))
	testing.expect(t, code == 0, "should succeed")
	out := string(bytes.buffer_to_bytes(&stdout))
	testing.expect(t, strings.has_prefix(out, "== "), "should print file header")
	testing.expect(t, strings.contains(out, "File"), "should print AST")
	testing.expect(t, !strings.contains(out, "KIND"), "should not print token table")
}

@(test)
test_run_file_token_mode :: proc(t: ^testing.T) {
	stdout, stderr: bytes.Buffer
	bytes.buffer_init(&stdout, {})
	bytes.buffer_init(&stderr, {})
	defer bytes.buffer_destroy(&stdout)
	defer bytes.buffer_destroy(&stderr)

	code := run({"-t", "cmd/print/testdata/hello.grammar"}, stdin_unused(), bytes.buffer_to_stream(&stdout), bytes.buffer_to_stream(&stderr))
	testing.expect(t, code == 0, "should succeed")
	out := string(bytes.buffer_to_bytes(&stdout))
	testing.expect(t, strings.contains(out, "KIND"), "should print token table header")
	testing.expect(t, strings.contains(out, "RuleDecl") == false, "token mode should not print AST")
}

@(test)
test_run_directory_ast :: proc(t: ^testing.T) {
	stdout, stderr: bytes.Buffer
	bytes.buffer_init(&stdout, {})
	bytes.buffer_init(&stderr, {})
	defer bytes.buffer_destroy(&stdout)
	defer bytes.buffer_destroy(&stderr)

	code := run({"cmd/print/testdata/errors"}, stdin_unused(), bytes.buffer_to_stream(&stdout), bytes.buffer_to_stream(&stderr))
	testing.expect(t, code == 1, "directory containing a bad grammar should fail")
	out := string(bytes.buffer_to_bytes(&stdout))
	testing.expect(t, strings.contains(out, "errors/bad.grammar"), "each file should get a header")
	err := string(bytes.buffer_to_bytes(&stderr))
	testing.expect(t, strings.contains(err, "expected RParen"), "parse errors should be reported")
}

@(test)
test_run_error_file_exits_nonzero :: proc(t: ^testing.T) {
	stdout, stderr: bytes.Buffer
	bytes.buffer_init(&stdout, {})
	bytes.buffer_init(&stderr, {})
	defer bytes.buffer_destroy(&stdout)
	defer bytes.buffer_destroy(&stderr)

	code := run({"cmd/print/testdata/errors/bad.grammar"}, stdin_unused(), bytes.buffer_to_stream(&stdout), bytes.buffer_to_stream(&stderr))
	testing.expect(t, code != 0, "should return non-zero")
	err := string(bytes.buffer_to_bytes(&stderr))
	testing.expect(t, strings.contains(err, "expected RParen"), "stderr should contain parse error")
}

@(test)
test_run_invalid_flag_fails :: proc(t: ^testing.T) {
	stdout, stderr: bytes.Buffer
	bytes.buffer_init(&stdout, {})
	bytes.buffer_init(&stderr, {})
	defer bytes.buffer_destroy(&stdout)
	defer bytes.buffer_destroy(&stderr)

	code := run({"--unknown", "cmd/print/testdata"}, stdin_unused(), bytes.buffer_to_stream(&stdout), bytes.buffer_to_stream(&stderr))
	testing.expect(t, code == 1, "should fail on invalid flags")
	err := string(bytes.buffer_to_bytes(&stderr))
	testing.expect(t, strings.contains(err, "invalid arguments"), "should report invalid arguments")
}

@(test)
test_run_no_path_fails :: proc(t: ^testing.T) {
	stdout, stderr: bytes.Buffer
	bytes.buffer_init(&stdout, {})
	bytes.buffer_init(&stderr, {})
	defer bytes.buffer_destroy(&stdout)
	defer bytes.buffer_destroy(&stderr)

	code := run({}, stdin_unused(), bytes.buffer_to_stream(&stdout), bytes.buffer_to_stream(&stderr))
	testing.expect(t, code == 1, "should fail without path")
	err := string(bytes.buffer_to_bytes(&stderr))
	testing.expect(t, strings.contains(err, "requires a PATH"), "should report missing path")
}