package normalizecmd

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

// run_normalize runs the command over args and collects both streams.
run_normalize :: proc(args: []string, stdin: io.Reader) -> Result {
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
// clearing a directory another is using would fail it. The parent is made here
// rather than by the tests, so that no two of them race to create it.
scratch_dir :: proc(t: ^testing.T, dir: string) -> string {
	// make_directory_all reports .Exist when the directory is already there, which
	// is not a failure here, so the result is left alone the way the check tests
	// leave it. A directory that could not be made fails on the write instead.
	os.remove_all(dir)
	os.make_directory_all(dir)
	return dir
}

// write_file writes src to rel, failing the test if it cannot.
write_file :: proc(t: ^testing.T, rel, src: string) {
	if err := os.write_entire_file(rel, src); err != nil {
		testing.fail_now(t, "could not write the fixture")
	}
}

// expect_argv fails the test unless the command returned code and wrote want on
// stdout.
expect_argv :: proc(t: ^testing.T, args: []string, stdin: io.Reader, code: int, want: string) {
	res := run_normalize(args, stdin)
	defer destroy_result(&res)
	testing.expectf(t, res.code == code, "exit %d, want %d (stderr: %s)", res.code, code, res.stderr)
	testing.expectf(t, res.stdout == want, "got %q, want %q", res.stdout, want)
}

// ---------------------------------------------------------------- normalize --

// A factored rule is written as its leading, a group of middles, and its
// trailing, which means what the branches it came from meant.
@(test)
test_normalize_writes_leading_a_group_and_trailing :: proc(t: ^testing.T) {
	src := "use = p a q | p b q;\n"
	expect_argv(t, []string{"--stdin"}, stdin_from(src), 0, "== <stdin> ==\nuse = p ( a | b ) q;\n")
}

// A file of rules comes out under a heading per file.
@(test)
test_normalize_headings_each_file :: proc(t: ^testing.T) {
	dir := scratch_dir(t, "cmd/normalize/testdata/scratch_headings")
	defer os.remove_all(dir)
	write_file(t, concat({dir, "/a.grammar"}), "one = a | b;\n")
	write_file(t, concat({dir, "/b.grammar"}), "two = c;\n")

	res := run_normalize([]string{dir}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 0, "exit 0, got %d", res.code)
	testing.expect(
		t,
		strings.contains(res.stdout, "== ") && strings.contains(res.stdout, "a.grammar"),
		res.stdout,
	)
	testing.expect(t, strings.contains(res.stdout, "two = c;"), res.stdout)
}

// The default drops a tag, so two branches tagged differently are the same
// production and the rule has one branch.
@(test)
test_normalize_drops_tags_by_default :: proc(t: ^testing.T) {
	src := "use = a `name=\"x\"` | a `name=\"y\"`;\n"
	expect_argv(t, []string{"--stdin"}, stdin_from(src), 0, "== <stdin> ==\nuse = a;\n")
}

@(test)
test_normalize_keeps_tags :: proc(t: ^testing.T) {
	src := "use = a `name=\"x\"` | a `name=\"y\"`;\n"
	res := run_normalize([]string{"--tags", "keep", "--stdin"}, stdin_from(src))
	defer destroy_result(&res)
	testing.expectf(t, res.code == 0, "exit 0, got %d", res.code)
	testing.expect(t, strings.contains(res.stdout, "`name=\"x\"`"), res.stdout)
	testing.expect(t, strings.contains(res.stdout, "`name=\"y\"`"), res.stdout)
}

// Under .Merge the tags of two branches annotating the same production are combined
// rather than dropped, and a pair name they share keeps the first of its two values.
@(test)
test_normalize_merges_tags :: proc(t: ^testing.T) {
	src := "use = a `kind=\"x\"` | a `name=\"y\"`;\n"
	res := run_normalize([]string{"--tags", "merge", "--stdin"}, stdin_from(src))
	defer destroy_result(&res)
	testing.expectf(t, res.code == 0, "exit 0, got %d", res.code)
	testing.expect(
		t,
		strings.contains(res.stdout, "use = a `kind=\"x\"; name=\"y\"`;"),
		res.stdout,
	)
	testing.expectf(t, res.stderr == "", "merge reports nothing: %s", res.stderr)

	clashing := "use = a `kind=\"x\"` | a `kind=\"y\"`;\n"
	res = run_normalize([]string{"--tags", "merge", "--stdin"}, stdin_from(clashing))
	defer destroy_result(&res)
	testing.expectf(t, res.code == 0, "exit 0, got %d", res.code)
	testing.expect(t, strings.contains(res.stdout, "use = a `kind=\"x\"`;"), res.stdout)
	testing.expect(t, strings.contains(res.stderr, "kind"), res.stderr)
}

// Under .Block the tag still goes, but losing it is said out loud.
@(test)
test_normalize_block_reports_a_dropped_tag :: proc(t: ^testing.T) {
	src := "use = a `name=\"x\"` | a `name=\"y\"`;\n"
	res := run_normalize([]string{"--tags", "block", "--stdin"}, stdin_from(src))
	defer destroy_result(&res)
	testing.expectf(t, res.code == 0, "exit 0, got %d", res.code)
	testing.expect(t, strings.contains(res.stderr, "name"), res.stderr)
	testing.expect(t, strings.contains(res.stdout, "use = a;"), res.stdout)
}

// A branch with nothing left in the middle has no factored form, so the rule is
// written as its branches whole and the run fails, which says the normal form was
// not reached for it.
@(test)
test_normalize_reports_an_empty_middle :: proc(t: ^testing.T) {
	src := "use = a b | a b c;\n"
	res := run_normalize([]string{"--stdin"}, stdin_from(src))
	defer destroy_result(&res)
	testing.expectf(t, res.code == 1, "exit 1, got %d", res.code)
	testing.expect(t, strings.contains(res.stderr, "written as its branches"), res.stderr)
	testing.expect(t, strings.contains(res.stdout, "use = a b | a b c;"), res.stdout)
	testing.expect(t, !strings.contains(res.stdout, "| c )"), "the empty middle should not be written")
}

// A call the scope cannot resolve is written as it stands and the run fails.
@(test)
test_normalize_reports_an_unexpanded_call :: proc(t: ^testing.T) {
	src := "use = <nope \"a\">;\n"
	res := run_normalize([]string{"--stdin"}, stdin_from(src))
	defer destroy_result(&res)
	testing.expectf(t, res.code == 1, "exit 1, got %d", res.code)
	testing.expect(t, strings.contains(res.stderr, "not every call"), res.stderr)
	testing.expect(t, strings.contains(res.stdout, "<nope \"a\">"), res.stdout)
}

// Normalizing is idempotent on anything without an empty middle, which is what
// makes --write settle after one pass.
@(test)
test_normalize_is_idempotent :: proc(t: ^testing.T) {
	dir := scratch_dir(t, "cmd/normalize/testdata/scratch_idempotent")
	defer os.remove_all(dir)
	path := concat({dir, "/n.grammar"})
	write_file(t, path, "use = p a q | p b q;\n")

	first := run_normalize([]string{"--write", path}, stdin_unused())
	defer destroy_result(&first)
	testing.expect(t, first.code == 0, "the first pass should be clean: %s", first.stderr)

	second := run_normalize([]string{"--write", path}, stdin_unused())
	defer destroy_result(&second)
	testing.expect(t, second.code == 0, "the second pass should be clean: %s", second.stderr)

	data, read_ok := os.read_entire_file(path, context.allocator)
	defer delete(data)
	testing.expect(t, read_ok == nil, "the rewritten file should be readable")
	testing.expectf(
		t,
		string(data) == "use = p ( a | b ) q;\n",
		"got %q",
		string(data),
	)
}

// A rule in one directory is not resolved against a rule of the same name in
// another, since a directory is a namespace.
@(test)
test_normalize_keeps_namespaces_apart :: proc(t: ^testing.T) {
	dir := scratch_dir(t, "cmd/normalize/testdata/scratch_namespaces")
	defer os.remove_all(dir)
	os.make_directory_all(concat({dir, "/sub"}))
	write_file(t, concat({dir, "/main.grammar"}), "Thing = \"x\";\n")
	write_file(t, concat({dir, "/sub/s.grammar"}), "use = <Thing>;\n")

	res := run_normalize([]string{dir}, stdin_unused())
	defer destroy_result(&res)
	testing.expect(t, res.code == 1, "a cross-namespace call cannot be expanded: %s", res.stdout)
	testing.expect(t, strings.contains(res.stdout, "<Thing>"), res.stdout)
}

@(test)
test_normalize_rejects_write_with_tree :: proc(t: ^testing.T) {
	res := run_normalize([]string{"--write", "--tree", "x.grammar"}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 1, "exit 1, got %d", res.code)
	testing.expect(t, strings.contains(res.stderr, "--write"), res.stderr)
}

@(test)
test_normalize_rejects_an_unknown_tag_policy :: proc(t: ^testing.T) {
	res := run_normalize([]string{"--tags", "bogus", "x.grammar"}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 1, "exit 1, got %d", res.code)
	testing.expect(t, strings.contains(res.stderr, "bogus"), res.stderr)
}

@(test)
test_normalize_rejects_an_unknown_flag :: proc(t: ^testing.T) {
	res := run_normalize([]string{"--nope", "x.grammar"}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 1, "exit 1, got %d", res.code)
	testing.expect(t, strings.contains(res.stderr, "invalid arguments"), res.stderr)
}

@(test)
test_normalize_requires_a_path :: proc(t: ^testing.T) {
	res := run_normalize([]string{}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 1, "exit 1, got %d", res.code)
	testing.expect(t, strings.contains(res.stderr, "requires a PATH"), res.stderr)
}

@(test)
test_normalize_rejects_a_path_outside_the_working_directory :: proc(t: ^testing.T) {
	res := run_normalize([]string{"../elsewhere"}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 1, "exit 1, got %d", res.code)
	testing.expect(t, strings.contains(res.stderr, "invalid path"), res.stderr)
}

// --tags with no value is an error rather than a path.
@(test)
test_normalize_rejects_a_tag_policy_with_no_value :: proc(t: ^testing.T) {
	res := run_normalize([]string{"--tags"}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 1, "exit 1, got %d", res.code)
	testing.expect(t, strings.contains(res.stderr, "needs a policy"), res.stderr)
}

// concat joins path fragments into the test's temporary memory, which is released
// when the test ends.
concat :: proc(parts: []string) -> string {
	return strings.concatenate(parts, context.temp_allocator)
}

// ------------------------------------------------------------------ select --

// --select transforms only the declaration the position falls in, and prints it
// without a heading.
@(test)
test_normalize_select_picks_one_declaration :: proc(t: ^testing.T) {
	dir := scratch_dir(t, "cmd/normalize/testdata/scratch_select")
	defer os.remove_all(dir)
	path := concat({dir, "/s.grammar"})
	write_file(t, path, "one = a | b;\nuse = p a q | p b q;\nother = c | d;\n")

	res := run_normalize([]string{"--select", "2:1", path}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 0, "exit 0, got %d (stderr: %s)", res.code, res.stderr)
	testing.expectf(t, res.stdout == "use = p ( a | b ) q;\n", "got %q", res.stdout)
}

// A rule the selected declaration is not is left out entirely rather than printed
// unchanged, since --select prints what it transformed.
@(test)
test_normalize_select_leaves_other_rules_out :: proc(t: ^testing.T) {
	dir := scratch_dir(t, "cmd/normalize/testdata/scratch_select_one")
	defer os.remove_all(dir)
	path := concat({dir, "/s.grammar"})
	write_file(t, path, "one = a | b;\n")

	res := run_normalize([]string{"--select", "1:1", path}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 0, "exit 0, got %d (stderr: %s)", res.code, res.stderr)
	testing.expectf(t, res.stdout == "one = ( a | b );\n", "got %q", res.stdout)
}

// The whole directory is still the scope, so a call in the selected declaration
// resolves against a rule the selection did not print.
@(test)
test_normalize_select_resolves_against_the_whole_scope :: proc(t: ^testing.T) {
	dir := scratch_dir(t, "cmd/normalize/testdata/scratch_select_scope")
	defer os.remove_all(dir)
	path := concat({dir, "/s.grammar"})
	write_file(t, path, "item x = x q;\nuse = <item \"a\"> | <item \"b\">;\n")

	res := run_normalize([]string{"--select", "2:1", path}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 0, "exit 0, got %d (stderr: %s)", res.code, res.stderr)
	testing.expectf(t, res.stdout == "use = ( \"a\" | \"b\" ) q;\n", "got %q", res.stdout)
}

@(test)
test_normalize_select_rejects_a_malformed_position :: proc(t: ^testing.T) {
	res := run_normalize([]string{"--select", "nope", "x.grammar"}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 1, "exit 1, got %d", res.code)
	testing.expect(t, strings.contains(res.stderr, "nope"), res.stderr)
}

@(test)
test_normalize_select_rejects_write :: proc(t: ^testing.T) {
	res := run_normalize([]string{"--write", "--select", "1:1", "x.grammar"}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 1, "exit 1, got %d", res.code)
	testing.expect(t, strings.contains(res.stderr, "--select"), res.stderr)
}

@(test)
test_normalize_select_rejects_stdin :: proc(t: ^testing.T) {
	res := run_normalize([]string{"--select", "1:1", "--stdin"}, stdin_from("a = \"x\";\n"))
	defer destroy_result(&res)
	testing.expectf(t, res.code == 1, "exit 1, got %d", res.code)
	testing.expect(t, strings.contains(res.stderr, "--stdin"), res.stderr)
}

// A selected declaration keeps its own diagnostic, since it is still expanded and
// factored on its own.
@(test)
test_normalize_select_reports_a_problem_in_the_selected_rule :: proc(t: ^testing.T) {
	dir := scratch_dir(t, "cmd/normalize/testdata/scratch_select_bad")
	defer os.remove_all(dir)
	path := concat({dir, "/s.grammar"})
	write_file(t, path, "use = <nope \"a\">;\n")

	res := run_normalize([]string{"--select", "1:1", path}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 1, "exit 1, got %d", res.code)
	testing.expect(t, strings.contains(res.stderr, "not every call"), res.stderr)
}

// ------------------------------------------------------- select in a package --

// A directory holds several files, so a selection names the one it is in, and only
// that file's declaration is written.
@(test)
test_normalize_select_names_a_file_of_a_directory :: proc(t: ^testing.T) {
	dir := scratch_dir(t, "cmd/normalize/testdata/scratch_select_file")
	defer os.remove_all(dir)
	write_file(t, concat({dir, "/a.grammar"}), "one = x y | x z;\n")
	write_file(t, concat({dir, "/b.grammar"}), "two = p a q | p b q;\n")

	res := run_normalize([]string{"--select", "b.grammar:1:1", dir}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 0, "exit 0, got %d (stderr: %s)", res.code, res.stderr)
	testing.expectf(t, res.stdout == "two = p ( a | b ) q;\n", "got %q", res.stdout)
}

// The file may be named by the path the input printed, or by its last segment
// alone, since the directory is already the argument.
@(test)
test_normalize_select_accepts_a_full_path_for_the_file :: proc(t: ^testing.T) {
	dir := scratch_dir(t, "cmd/normalize/testdata/scratch_select_path")
	defer os.remove_all(dir)
	write_file(t, concat({dir, "/b.grammar"}), "two = p a q | p b q;\n")

	res := run_normalize(
		[]string{"--select", concat({dir, "/b.grammar", ":1:1"}), dir},
		stdin_unused(),
	)
	defer destroy_result(&res)
	testing.expectf(t, res.code == 0, "exit 0, got %d (stderr: %s)", res.code, res.stderr)
	testing.expectf(t, res.stdout == "two = p ( a | b ) q;\n", "got %q", res.stdout)
}

// A file no selection names is left alone rather than reported, so the selection
// reaches one file of a package quietly.
@(test)
test_normalize_select_leaves_the_other_files_quiet :: proc(t: ^testing.T) {
	dir := scratch_dir(t, "cmd/normalize/testdata/scratch_select_quiet")
	defer os.remove_all(dir)
	write_file(t, concat({dir, "/a.grammar"}), "one = <nope>;\n")
	write_file(t, concat({dir, "/b.grammar"}), "two = p a q | p b q;\n")

	res := run_normalize([]string{"--select", "b.grammar:1:1", dir}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 0, "the unselected file must not be reported: %s", res.stderr)
	testing.expect(t, res.stderr == "", "nothing should be reported")
	testing.expectf(t, res.stdout == "two = p ( a | b ) q;\n", "got %q", res.stdout)
}

// A file that is not part of the input is a mistake worth saying so about.
@(test)
test_normalize_select_reports_a_file_outside_the_input :: proc(t: ^testing.T) {
	dir := scratch_dir(t, "cmd/normalize/testdata/scratch_select_absent")
	defer os.remove_all(dir)
	write_file(t, concat({dir, "/a.grammar"}), "one = a | b;\n")

	res := run_normalize([]string{"--select", "nope.grammar:1:1", dir}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 1, "exit 1, got %d", res.code)
	testing.expect(t, strings.contains(res.stderr, "nope.grammar"), res.stderr)
}

// A bare position still applies to every file, which is what it did before a
// selection could name one.
@(test)
test_normalize_select_bare_position_applies_to_every_file :: proc(t: ^testing.T) {
	dir := scratch_dir(t, "cmd/normalize/testdata/scratch_select_bare")
	defer os.remove_all(dir)
	write_file(t, concat({dir, "/a.grammar"}), "one = p a q | p b q;\n")
	write_file(t, concat({dir, "/b.grammar"}), "two = p a q | p b q;\n")

	res := run_normalize([]string{"--select", "1:1", dir}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 0, "exit 0, got %d (stderr: %s)", res.code, res.stderr)
	testing.expect(t, strings.contains(res.stdout, "one = p ( a | b ) q;"), res.stdout)
	testing.expect(t, strings.contains(res.stdout, "two = p ( a | b ) q;"), res.stdout)
}

// A file of a directory that does not reach the line a bare position names is passed
// over instead of reported, so a bare position over a package is usable. The first
// file is written without a break at the end, so it has one line and no second.
@(test)
test_normalize_select_bare_position_passes_over_a_short_file :: proc(t: ^testing.T) {
	dir := scratch_dir(t, "cmd/normalize/testdata/scratch_select_short")
	defer os.remove_all(dir)
	write_file(t, concat({dir, "/a.grammar"}), "one = a;")
	write_file(t, concat({dir, "/b.grammar"}), "one = b;\ntwo = p x | p y;\n")

	res := run_normalize([]string{"--select", "2:1", dir}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 0, "exit 0, got %d (stderr: %s)", res.code, res.stderr)
	testing.expectf(t, res.stdout == "two = p ( x | y );\n", "got %q", res.stdout)
}

// The file of a selection is a path like any other.
@(test)
test_normalize_select_rejects_a_file_outside_the_working_directory :: proc(t: ^testing.T) {
	res := run_normalize([]string{"--select", "../elsewhere:1:1", "x.grammar"}, stdin_unused())
	defer destroy_result(&res)
	testing.expectf(t, res.code == 1, "exit 1, got %d", res.code)
	testing.expect(t, strings.contains(res.stderr, "invalid path"), res.stderr)
}
