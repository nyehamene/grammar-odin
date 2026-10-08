package expandcmd

import "core:bytes"
import "core:io"
import "core:os"
import "core:strings"
import "core:testing"

// stdin_unused returns an empty reader for tests that write to disk.
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

// Result is what a command wrote and returned.
Result :: struct {
	code:   int,
	stdout: string,
	stderr: string,
}

// run_expand runs the command over args and collects both streams.
run_expand :: proc(args: []string, stdin: io.Reader) -> Result {
	out: bytes.Buffer
	bytes.buffer_init(&out, {})
	errs: bytes.Buffer
	bytes.buffer_init(&errs, {})

	code := run(args, stdin, bytes.buffer_to_stream(&out), bytes.buffer_to_stream(&errs))

	res := Result {
		code   = code,
		stdout = strings.clone(bytes.buffer_to_string(&out), context.allocator),
		stderr = strings.clone(bytes.buffer_to_string(&errs), context.allocator),
	}
	bytes.buffer_destroy(&out)
	bytes.buffer_destroy(&errs)
	return res
}

destroy_result :: proc(r: ^Result) {
	delete(r.stdout)
	delete(r.stderr)
}

// scratch_dir removes anything at dir, creates it, and returns the path. The
// caller removes it again.
//
// Each test gets a directory of its own, since the runner is parallel and one test
// clearing a directory another is using would fail it. make_directory_all reports
// .Exist when the directory is already there, which is not a failure here, so the
// result is left alone the way the check tests leave it.
// Each test names a directory of its own with no shared parent, so that the runner
// being parallel cannot have one test clearing a directory another is using.
// make_directory_all reports .Exist when the directory is already there, which is
// not a failure here, so the result is left alone.
scratch_dir :: proc(t: ^testing.T, dir: string) -> string {
	os.remove_all(dir)
	os.make_directory_all(dir)
	return dir
}

// write_file writes src to path, failing the test if it cannot.
write_file :: proc(t: ^testing.T, path, src: string) {
	if err := os.write_entire_file(path, src); err != nil {
		testing.fail_now(t, "could not write the fixture")
	}
}

// expect_stdin fails the test unless the command returned code and wrote want.
expect_stdin :: proc(t: ^testing.T, args: []string, src: string, code: int, want: string) {
	res := run_expand(args, stdin_from(src))
	defer destroy_result(&res)
	testing.expectf(t, res.code == code, "exit %d, want %d (stderr: %s)", res.code, code, res.stderr)
	testing.expectf(t, res.stdout == want, "got %q, want %q", res.stdout, want)
}

// ------------------------------------------------------------------ expand --

// A call is replaced by the body of the rule it names, with the arguments put
// where the parameters were.
@(test)
test_expand_inlines_a_call :: proc(t: ^testing.T) {
	expect_stdin(
		t,
		[]string{"--stdin"},
		"item x = x { x };\nuse = <item \"a\">;\n",
		0,
		"== <stdin> ==\nitem x = x { x };\nuse = \"a\" { \"a\" };\n",
	)
}

// A call in the middle of a body is expanded along with the ones around it.
@(test)
test_expand_inlines_a_call_among_others :: proc(t: ^testing.T) {
	expect_stdin(
		t,
		[]string{"--stdin"},
		"item x = x;\nuse = \"a\" <item \"i\"> \"b\";\n",
		0,
		"== <stdin> ==\nitem x = x;\nuse = \"a\" \"i\" \"b\";\n",
	)
}

// Expansion is idempotent, since a body with no call in it is its own expansion.
@(test)
test_expand_leaves_a_call_free_file_alone :: proc(t: ^testing.T) {
	src := "a = \"x\" | \"y\";\nb = a { a };\n"
	expect_stdin(
		t,
		[]string{"--stdin"},
		src,
		0,
		"== <stdin> ==\na = \"x\"\n  | \"y\"\n  ;\nb = a { a };\n",
	)
}

// A comment on a line of its own is a declaration of its own, so it survives, and a
// bare reference to another rule is not a call, so it is left as it stands.
@(test)
test_expand_keeps_a_comment_between_rules :: proc(t: ^testing.T) {
	expect_stdin(
		t,
		[]string{"--stdin"},
		"// one\na = \"x\";\n// two\nb = a;\n",
		0,
		"== <stdin> ==\n// one\na = \"x\";\n// two\nb = a;\n",
	)
}

@(test)
test_expand_drops_a_comment_inside_a_body :: proc(t: ^testing.T) {
	expect_stdin(t, []string{"--stdin"}, "a = \"x\" // why\n  ;\n", 0, "== <stdin> ==\na = \"x\";\n")
}

// An import binding has no body, so it is written back as it stands.
@(test)
test_expand_keeps_an_import_binding :: proc(t: ^testing.T) {
	expect_stdin(
		t,
		[]string{"--stdin"},
		"f = @import(\"base\");\na = \"x\";\n",
		0,
		"== <stdin> ==\nf = @import(\"base\");\na = \"x\";\n",
	)
}

// A call the scope cannot resolve is written as it stands and reported, with a
// non-zero exit code so that a script notices it.
@(test)
test_expand_reports_an_unresolved_call :: proc(t: ^testing.T) {
	res := run_expand([]string{"--stdin"}, stdin_from("use = <nope \"a\">;\n"))
	defer destroy_result(&res)
	testing.expectf(t, res.code == 1, "exit 1, got %d", res.code)
	testing.expect(t, strings.contains(res.stderr, "not every call"), res.stderr)
	testing.expect(t, strings.contains(res.stdout, "<nope \"a\">"), res.stdout)
}

// A rule in one directory is not resolved against a rule of the same name in
// another, since a directory is a namespace.
@(test)
test_expand_keeps_namespaces_apart :: proc(t: ^testing.T) {
	dir := scratch_dir(t, "cmd/expand/testdata/scratch_namespaces")
	defer os.remove_all(dir)
	os.make_directory_all(concat({dir, "/sub"}))
	write_file(t, concat({dir, "/main.grammar"}), "Thing = \"x\";\n")
	write_file(t, concat({dir, "/sub/s.grammar"}), "use = <Thing>;\n")

	res := run_expand([]string{dir}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 1, "a cross-namespace call cannot be expanded: %s", res.stdout)
	testing.expect(t, strings.contains(res.stdout, "<Thing>"), res.stdout)
}

// --write puts the result back where it came from.
@(test)
test_expand_writes_in_place :: proc(t: ^testing.T) {
	dir := scratch_dir(t, "cmd/expand/testdata/scratch_write")
	defer os.remove_all(dir)
	path := concat({dir, "/e.grammar"})
	write_file(t, path, "item x = x;\nuse = <item \"i\">;\n")

	res := run_expand([]string{"--write", path}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 0, "exit 0, got %d (stderr: %s)", res.code, res.stderr)

	data, read_err := os.read_entire_file(path, context.allocator)
	defer delete(data)
	testing.expect(t, read_err == nil, "the rewritten file should be readable")
	testing.expectf(t, string(data) == "item x = x;\nuse = \"i\";\n", "got %q", string(data))
}

// Without --write the file is only read.
@(test)
test_expand_leaves_the_file_alone_without_write :: proc(t: ^testing.T) {
	dir := scratch_dir(t, "cmd/expand/testdata/scratch_stdout")
	defer os.remove_all(dir)
	path := concat({dir, "/e.grammar"})
	src := "item x = x;\nuse = <item \"i\">;\n"
	write_file(t, path, src)

	res := run_expand([]string{path}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 0, "exit 0, got %d (stderr: %s)", res.code, res.stderr)

	data, read_err := os.read_entire_file(path, context.allocator)
	defer delete(data)
	testing.expect(t, read_err == nil, "the file should be readable")
	testing.expect(t, string(data) == src, "the file should not have been rewritten")
}

@(test)
test_expand_rejects_write_with_tree :: proc(t: ^testing.T) {
	res := run_expand([]string{"--write", "--tree", "x.grammar"}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 1, "exit 1, got %d", res.code)
	testing.expect(t, strings.contains(res.stderr, "--write"), res.stderr)
}

@(test)
test_expand_rejects_an_unknown_flag :: proc(t: ^testing.T) {
	res := run_expand([]string{"--nope", "x.grammar"}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 1, "exit 1, got %d", res.code)
	testing.expect(t, strings.contains(res.stderr, "invalid arguments"), res.stderr)
}

@(test)
test_expand_requires_a_path :: proc(t: ^testing.T) {
	res := run_expand([]string{}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 1, "exit 1, got %d", res.code)
	testing.expect(t, strings.contains(res.stderr, "requires a PATH"), res.stderr)
}

@(test)
test_expand_rejects_a_path_outside_the_working_directory :: proc(t: ^testing.T) {
	res := run_expand([]string{"../elsewhere"}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 1, "exit 1, got %d", res.code)
	testing.expect(t, strings.contains(res.stderr, "invalid path"), res.stderr)
}

// A file that does not parse is reported and left out rather than transformed.
@(test)
test_expand_reports_a_broken_file :: proc(t: ^testing.T) {
	res := run_expand([]string{"--stdin"}, stdin_from("a = (\n"))
	defer destroy_result(&res)
	testing.expectf(t, res.code == 1, "exit 1, got %d", res.code)
	testing.expect(t, strings.contains(res.stderr, "<stdin>"), res.stderr)
}

// concat joins path fragments into the test's temporary memory.
concat :: proc(parts: []string) -> string {
	return strings.concatenate(parts, context.temp_allocator)
}

// ------------------------------------------------------------------ select --

// --select transforms only the declaration the position falls in, and prints it
// without a heading.
@(test)
test_expand_select_picks_one_declaration :: proc(t: ^testing.T) {
	dir := scratch_dir(t, "cmd/expand/testdata/scratch_select")
	defer os.remove_all(dir)
	path := concat({dir, "/s.grammar"})
	write_file(t, path, "item x = x;\nuse = <item \"i\">;\nother = <item \"i\">;\n")

	res := run_expand([]string{"--select", "2:1", path}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 0, "exit 0, got %d (stderr: %s)", res.code, res.stderr)
	testing.expectf(t, res.stdout == "use = \"i\";\n", "got %q", res.stdout)
}

// The position is where the declaration starts, or anywhere inside it, and the
// column is not the offset.
@(test)
test_expand_select_accepts_a_column_inside_the_declaration :: proc(t: ^testing.T) {
	dir := scratch_dir(t, "cmd/expand/testdata/scratch_select_column")
	defer os.remove_all(dir)
	path := concat({dir, "/s.grammar"})
	write_file(t, path, "item x = x;\nuse = <item \"i\">;\n")

	res := run_expand([]string{"--select", "2:7", path}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 0, "exit 0, got %d (stderr: %s)", res.code, res.stderr)
	testing.expectf(t, res.stdout == "use = \"i\";\n", "got %q", res.stdout)
}

// A position past the end of the file names no declaration, and saying so once for
// the whole input is more use than saying it per file.
@(test)
test_expand_select_rejects_a_position_outside_any_declaration :: proc(t: ^testing.T) {
	dir := scratch_dir(t, "cmd/expand/testdata/scratch_select_none")
	defer os.remove_all(dir)
	path := concat({dir, "/s.grammar"})
	write_file(t, path, "a = \"x\";\n")

	res := run_expand([]string{"--select", "9:1", path}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 1, "exit 1, got %d", res.code)
	testing.expect(t, strings.contains(res.stderr, "9:1"), res.stderr)
	testing.expect(t, res.stdout == "", "nothing should be written")
}

// Text that is not a position at all is named back.
@(test)
test_expand_select_rejects_a_malformed_position :: proc(t: ^testing.T) {
	res := run_expand([]string{"--select", "nope", "x.grammar"}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 1, "exit 1, got %d", res.code)
	testing.expect(t, strings.contains(res.stderr, "nope"), res.stderr)
}

@(test)
test_expand_select_rejects_a_missing_position :: proc(t: ^testing.T) {
	res := run_expand([]string{"--select"}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 1, "exit 1, got %d", res.code)
	testing.expect(t, strings.contains(res.stderr, "invalid arguments"), res.stderr)
}

// A selected declaration goes to stdout, so it cannot also be written back.
@(test)
test_expand_select_rejects_write :: proc(t: ^testing.T) {
	res := run_expand([]string{"--write", "--select", "1:1", "x.grammar"}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 1, "exit 1, got %d", res.code)
	testing.expect(t, strings.contains(res.stderr, "--select"), res.stderr)
}

@(test)
test_expand_select_rejects_stdin :: proc(t: ^testing.T) {
	res := run_expand([]string{"--select", "1:1", "--stdin"}, stdin_from("a = \"x\";\n"))
	defer destroy_result(&res)
	testing.expectf(t, res.code == 1, "exit 1, got %d", res.code)
	testing.expect(t, strings.contains(res.stderr, "--stdin"), res.stderr)
}

// The path may come before or after the flag.
@(test)
test_expand_select_may_follow_the_path :: proc(t: ^testing.T) {
	dir := scratch_dir(t, "cmd/expand/testdata/scratch_select_after")
	defer os.remove_all(dir)
	path := concat({dir, "/s.grammar"})
	write_file(t, path, "item x = x;\nuse = <item \"i\">;\n")

	after := run_expand([]string{path, "--select", "2:1"}, stdin_unused())
	defer destroy_result(&after)
	before := run_expand([]string{"--select", "2:1", path}, stdin_unused())
	defer destroy_result(&before)
	testing.expectf(t, after.stdout == before.stdout, "got %q then %q", before.stdout, after.stdout)
	testing.expectf(t, after.stdout == "use = \"i\";\n", "got %q", after.stdout)
}

// ------------------------------------------------------- select in a package --

// A directory holds several files, so a selection names the one it is in, and only
// that file's declaration is written.
@(test)
test_expand_select_names_a_file_of_a_directory :: proc(t: ^testing.T) {
	dir := scratch_dir(t, "cmd/expand/testdata/scratch_select_file")
	defer os.remove_all(dir)
	write_file(t, concat({dir, "/a.grammar"}), "one = <nope>;\n")
	write_file(t, concat({dir, "/b.grammar"}), "item x = x;\ntwo = <item \"i\">;\n")

	res := run_expand([]string{"--select", "b.grammar:2:1", dir}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 0, "exit 0, got %d (stderr: %s)", res.code, res.stderr)
	testing.expectf(t, res.stdout == "two = \"i\";\n", "got %q", res.stdout)
}

// The file may be named by the path the input printed, or by any tail of it, since a
// directory is walked into absolute paths.
@(test)
test_expand_select_accepts_a_path_for_the_file :: proc(t: ^testing.T) {
	dir := scratch_dir(t, "cmd/expand/testdata/scratch_select_path")
	defer os.remove_all(dir)
	write_file(t, concat({dir, "/b.grammar"}), "item x = x;\ntwo = <item \"i\">;\n")

	res := run_expand(
		[]string{"--select", concat({dir, "/b.grammar", ":2:1"}), dir},
		stdin_unused(),
	)
	defer destroy_result(&res)
	testing.expectf(t, res.code == 0, "exit 0, got %d (stderr: %s)", res.code, res.stderr)
	testing.expectf(t, res.stdout == "two = \"i\";\n", "got %q", res.stdout)
}

// A file of the input that the selection does not name is left alone and unreported,
// so an unresolvable call in it does not fail the run.
@(test)
test_expand_select_leaves_the_other_files_quiet :: proc(t: ^testing.T) {
	dir := scratch_dir(t, "cmd/expand/testdata/scratch_select_quiet")
	defer os.remove_all(dir)
	write_file(t, concat({dir, "/a.grammar"}), "one = <nope>;\n")
	write_file(t, concat({dir, "/b.grammar"}), "item x = x;\ntwo = <item \"i\">;\n")

	res := run_expand([]string{"--select", "b.grammar:2:1", dir}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 0, "the unselected file must not be reported: %s", res.stderr)
	testing.expect(t, res.stderr == "", "nothing should be reported")
}

@(test)
test_expand_select_reports_a_file_outside_the_input :: proc(t: ^testing.T) {
	dir := scratch_dir(t, "cmd/expand/testdata/scratch_select_absent")
	defer os.remove_all(dir)
	write_file(t, concat({dir, "/a.grammar"}), "one = \"a\";\n")

	res := run_expand([]string{"--select", "nope.grammar:1:1", dir}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 1, "exit 1, got %d", res.code)
	testing.expect(t, strings.contains(res.stderr, "nope.grammar"), res.stderr)
}
