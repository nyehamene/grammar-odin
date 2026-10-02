package check

import "core:bytes"
import "core:fmt"
import "core:os"
import "core:sort"
import "core:strings"
import "core:testing"

// Mem_File is a grammar source loaded into a compilation unit from memory.
// abs identifies the file and its namespace directory; display is the path
// shown in diagnostics; src is referenced, not copied.
Mem_File :: struct {
	abs:     string,
	display: string,
	src:     string,
}

// cat joins two path fragments.
cat :: proc(a, b: string) -> string {
	return strings.concatenate({a, b})
}

// run_semantics loads the given in-memory files into a fresh compilation unit,
// runs the binding and type-checking phases, and returns the diagnostics as
// "path:line:col: message" strings. The returned strings are owned by the
// caller; the compilation unit is destroyed.
run_semantics :: proc(files: []Mem_File) -> [dynamic]string {
	cu := new_compilation_unit()
	defer destroy_compilation_unit(&cu)

	for f in files {
		load_source(&cu, strings.clone(f.abs), strings.clone(f.display), f.src)
	}
	run_checks(&cu)
	return collect_messages(&cu)
}

// collect_messages formats every diagnostic in cu as "path:line:col: message",
// sorted by path, line and column. The returned strings are owned by the
// caller.
collect_messages :: proc(cu: ^Compilation_Unit) -> [dynamic]string {
	messages := make([dynamic]string, len(cu.errors))
	for e, i in cu.errors {
		b := strings.builder_make()
		strings.write_string(&b, e.path)
		strings.write_rune(&b, ':')
		strings.write_int(&b, e.line)
		strings.write_rune(&b, ':')
		strings.write_int(&b, e.col)
		strings.write_string(&b, ": ")
		strings.write_string(&b, e.message)
		messages[i] = strings.clone(strings.to_string(b))
		strings.builder_destroy(&b)
	}
	sort.quick_sort_proc(messages[:], cmp_string)
	return messages
}

// assert_messages checks that got matches the expected diagnostics.
assert_messages :: proc(t: ^testing.T, got: [dynamic]string, want: []string) {
	defer {
		for m in got do delete(m)
		delete(got)
	}
	if len(got) != len(want) {
		testing.expectf(t, false, "got %d diagnostics, want %d\n", len(got), len(want))
		for g in got {
			testing.expectf(t, false, "  got:  %s\n", g)
		}
		for w in want {
			testing.expectf(t, false, "  want: %s\n", w)
		}
		return
	}
	for g, i in got {
		testing.expect(t, g == want[i], "diagnostic mismatch")
		if g != want[i] {
			testing.expectf(t, false, "got : %s\nwant: %s", g, want[i])
		}
	}
}

cmp_string :: proc(a, b: string) -> int {
	return -1 if a < b else 1 if a > b else 0
}

// write_test_file writes src to path and fails the test if the write fails.
write_test_file :: proc(t: ^testing.T, path, src: string) {
	if err := os.write_entire_file(path, src); err != nil {
		testing.fail_now(t, "failed to write test file")
	}
}

// test_abs returns the absolute form of a path relative to the test working
// directory (the repository root when `odin test` runs). The caller owns the
// result.
test_abs :: proc(t: ^testing.T, rel: string) -> string {
	cwd, err := os.get_working_directory(context.temp_allocator)
	if err != nil || cwd == "" {
		testing.fail_now(t, "failed to get working directory")
	}
	return strings.concatenate({cwd, "/", rel})
}

// scratch_dir removes any existing content at rel, creates it, and returns its
// absolute path. The caller must delete the result.
scratch_dir :: proc(t: ^testing.T, rel: string) -> string {
	os.remove_all(rel)
	os.make_directory_all(rel)
	return test_abs(t, rel)
}

// test_src returns a Mem_File with the given display name, rooted in a fake
// /tmp directory that depends on the dir argument so parallel tests never
// share a namespace.
test_src :: proc(t: ^testing.T, dir, display, src: string) -> Mem_File {
	return Mem_File {
		abs = fmt.tprintf("/tmp/grammar_ut/%s/%s", dir, display),
		display = display,
		src = src,
	}
}

@(test)
test_valid_program_has_no_errors :: proc(t: ^testing.T) {
	src :=
		"a = \"x\";\n" +
		"b = a | b;\n" +
		"c = a b;\n" +
		"d = [a] { b };\n" +
		"e = ( b );\n" +
		"f = __ext__;\n" +
		"g x = x;\n" +
		"h = <g a>;\n"
	assert_messages(t, run_semantics([]Mem_File{test_src(t, "valid", "main.grammar", src)}), {})
}

@(test)
test_undefined_identifier :: proc(t: ^testing.T) {
	src := "a = \"x\";\nb = c;\n"
	msgs := run_semantics([]Mem_File{test_src(t, "undef", "main.grammar", src)})
	assert_messages(t, msgs, {"main.grammar:2:5: undefined identifier: c"})
}

@(test)
test_local_rule_visible_only_in_its_file :: proc(t: ^testing.T) {
	// `_axe` is a local rule declared in a.grammar; b.grammar in the same
	// namespace cannot see it.
	files := []Mem_File {
		test_src(t, "locals", "a.grammar", "_axe = \"x\";\n"),
		test_src(t, "locals", "b.grammar", "use = _axe;\n"),
	}
	msgs := run_semantics(files)
	assert_messages(t, msgs, {"b.grammar:1:7: undefined identifier: _axe"})
}

@(test)
test_lowercase_rule_is_shared_across_files :: proc(t: ^testing.T) {
	// Only an underscore prefix makes a rule local; a lowercase name is an
	// ordinary namespace rule and is visible in sibling files.
	files := []Mem_File {
		test_src(t, "shared", "a.grammar", "expr = \"x\";\n"),
		test_src(t, "shared", "b.grammar", "use = expr;\n"),
	}
	assert_messages(t, run_semantics(files), {})
}

@(test)
test_local_rules_do_not_collide_across_files :: proc(t: ^testing.T) {
	// Two files may each declare a local rule with the same name.
	files := []Mem_File {
		test_src(t, "collide", "a.grammar", "_item = \"a\";\n"),
		test_src(t, "collide", "b.grammar", "_item = \"b\";\n"),
	}
	assert_messages(t, run_semantics(files), {})
}

@(test)
test_malformed_local_rule_names :: proc(t: ^testing.T) {
	// A bare `_` and a name whose second character is not a letter are both
	// rejected. `__c` is no longer malformed-local territory: a "__" prefix
	// followed by a letter scans as an external, so it cannot name a rule at
	// all. The malformed rule is still registered in the namespace so the rest
	// of the file keeps resolving.
	src := "_ = \"a\";\n_1b = \"b\";\n__1c = \"c\";\nd = _;\n"
	msgs := run_semantics([]Mem_File{test_src(t, "badlocal", "main.grammar", src)})
	assert_messages(
		t,
		msgs,
		{
			"main.grammar:1:1: malformed local rule name _. a local rule name is an underscore followed by a letter, as in _helper",
			"main.grammar:2:1: malformed local rule name _1b. a local rule name is an underscore followed by a letter, as in _helper",
			"main.grammar:3:1: malformed local rule name __1c. a local rule name is an underscore followed by a letter, as in _helper",
		},
	)
}

// A "__"-prefixed name is an external, never a rule, so it cannot be declared.
@(test)
test_external_cannot_name_a_rule :: proc(t: ^testing.T) {
	src := "__c = \"c\";\nOk = \"d\";\n"
	msgs := run_semantics([]Mem_File{test_src(t, "extdecl", "main.grammar", src)})
	assert_messages(t, msgs, {"main.grammar:1:1: expected IDENT, got External"})
}

@(test)
test_redeclared_in_same_file :: proc(t: ^testing.T) {
	src := "Foo = \"a\";\nFoo = \"b\";\n"
	msgs := run_semantics([]Mem_File{test_src(t, "redecl", "main.grammar", src)})
	assert_messages(
		t,
		msgs,
		{
			"main.grammar:2:1: field Foo redeclared in this namespace. (see other declaration at main.grammar:1:1)",
		},
	)
}

@(test)
test_redeclared_across_files :: proc(t: ^testing.T) {
	files := []Mem_File {
		test_src(t, "dup", "a.grammar", "Thing = \"a\";\n"),
		test_src(t, "dup", "b.grammar", "Thing = \"b\";\n"),
	}
	msgs := run_semantics(files)
	assert_messages(
		t,
		msgs,
		{
			"b.grammar:1:1: field Thing redeclared in this namespace. (see other declaration at a.grammar:1:1)",
		},
	)
}

// A rule with parameters (a proc) must be called; using it bare as a
// production is an error.
@(test)
test_proc_used_as_production :: proc(t: ^testing.T) {
	src := "foo x = x;\nb = foo;\n"
	assert_messages(
		t,
		run_semantics([]Mem_File{test_src(t, "proc", "main.grammar", src)}),
		{"main.grammar:2:5: proc cannot be used as a production: foo"},
	)
}

@(test)
test_proc_call_arity :: proc(t: ^testing.T) {
	src :=
		"a = \"y\";\n" +
		"b = \"z\";\n" +
		"p x = x;\n" +
		"ok = <p a>;\n" +
		"too_many = <p a b>;\n" +
		"too_few = <p>;\n"
	msgs := run_semantics([]Mem_File{test_src(t, "arity", "main.grammar", src)})
	assert_messages(
		t,
		msgs,
		{
			"main.grammar:5:13: proc 'p' expects 1 argument, but got 2",
			"main.grammar:6:12: proc 'p' expects 1 argument, but got 0",
		},
	)
}

@(test)
test_unused_proc_parameter :: proc(t: ^testing.T) {
	src := "n x y = x;\n"
	msgs := run_semantics([]Mem_File{test_src(t, "unusedparam", "main.grammar", src)})
	assert_messages(t, msgs, {"main.grammar:1:5: unused proc parameter: y"})
}

@(test)
test_call_on_non_callable :: proc(t: ^testing.T) {
	src := "a = \"x\";\nb = <a \"y\">;\nc x = <x a>;"
	msgs := run_semantics([]Mem_File{test_src(t, "callable", "main.grammar", src)})
	assert_messages(
		t,
		msgs,
		{"main.grammar:2:6: not callable: 'a'", "main.grammar:3:8: not callable: 'x'"},
	)
}

@(test)
test_external_value_passed_to_call :: proc(t: ^testing.T) {
	src := "p x = x;\nb = <p __ext__>;\n"
	msgs := run_semantics([]Mem_File{test_src(t, "ext", "main.grammar", src)})
	assert_messages(t, msgs, {"main.grammar:2:8: external cannot be pass as proc argument: ext"})
}

@(test)
test_member_of_non_namespace :: proc(t: ^testing.T) {
	src := "a = \"x\";\nb = a.c;\n"
	msgs := run_semantics([]Mem_File{test_src(t, "member", "main.grammar", src)})
	assert_messages(
		t,
		msgs,
		{"main.grammar:2:7: expected a namespace, but 'a' is not a namespace"},
	)
}

@(test)
test_member_object_undefined :: proc(t: ^testing.T) {
	src := "b = c.x;\n"
	msgs := run_semantics([]Mem_File{test_src(t, "memberundef", "main.grammar", src)})
	assert_messages(
		t,
		msgs,
		{
			"main.grammar:1:5: expected a namespace on the left of '.'",
			"main.grammar:1:5: undefined identifier: c",
		},
	)
}

// ---------------------------------------------------------------------------
// Import-based checks need real directories on disk because namespaces resolve
// relative to the importing file's directory.
// ---------------------------------------------------------------------------

@(test)
test_import_valid_member_access :: proc(t: ^testing.T) {
	root := scratch_dir(t, "cmd/check/testdata/scratch/import_ok")
	defer os.remove_all("cmd/check/testdata/scratch/import_ok")
	defer delete(root)

	base := cat(root, "/base")
	defer delete(base)
	os.make_directory_all(base)
	rgram := cat(base, "/r.grammar")
	defer delete(rgram)
	write_test_file(t, rgram, "R = \"x\";\n")

	abs := cat(root, "/main.grammar")
	defer delete(abs)
	src := "ns = @import(\"./base\");\nuse = ns.R;\n"
	files := []Mem_File{{abs = abs, display = "main.grammar", src = src}}
	assert_messages(t, run_semantics(files), {})
}

@(test)
test_import_undefined_member :: proc(t: ^testing.T) {
	root := scratch_dir(t, "cmd/check/testdata/scratch/import_missing")
	defer os.remove_all("cmd/check/testdata/scratch/import_missing")
	defer delete(root)

	base := cat(root, "/base")
	defer delete(base)
	os.make_directory_all(base)
	rgram := cat(base, "/r.grammar")
	defer delete(rgram)
	write_test_file(t, rgram, "R = \"x\";\n")

	abs := cat(root, "/main.grammar")
	defer delete(abs)
	src := "ns = @import(\"./base\");\nuse = ns.Missing;\n"
	files := []Mem_File{{abs = abs, display = "main.grammar", src = src}}
	msgs := run_semantics(files)
	assert_messages(
		t,
		msgs,
		{"main.grammar:2:10: ns.Missing is undefined. namespace base has no field Missing"},
	)
}

@(test)
test_namespace_used_as_production :: proc(t: ^testing.T) {
	root := scratch_dir(t, "cmd/check/testdata/scratch/import_ns_prod")
	defer os.remove_all("cmd/check/testdata/scratch/import_ns_prod")
	defer delete(root)

	base := cat(root, "/base")
	defer delete(base)
	os.make_directory_all(base)
	rgram := cat(base, "/r.grammar")
	defer delete(rgram)
	write_test_file(t, rgram, "R = \"x\";\n")

	abs := cat(root, "/main.grammar")
	defer delete(abs)
	src := "ns = @import(\"./base\");\nuse = ns;\n"
	files := []Mem_File{{abs = abs, display = "main.grammar", src = src}}
	msgs := run_semantics(files)
	assert_messages(t, msgs, {"main.grammar:2:7: namespace cannot be used as an production: ns"})
}

@(test)
test_namespace_passed_to_call :: proc(t: ^testing.T) {
	root := scratch_dir(t, "cmd/check/testdata/scratch/import_ns_call")
	defer os.remove_all("cmd/check/testdata/scratch/import_ns_call")
	defer delete(root)

	base := cat(root, "/base")
	defer delete(base)
	os.make_directory_all(base)
	rgram := cat(base, "/r.grammar")
	defer delete(rgram)
	write_test_file(t, rgram, "R = \"x\";\n")

	abs := cat(root, "/main.grammar")
	defer delete(abs)
	src := "p x = x;\nns = @import(\"./base\");\nuse = <p ns>;\n"
	files := []Mem_File{{abs = abs, display = "main.grammar", src = src}}
	msgs := run_semantics(files)
	assert_messages(t, msgs, {"main.grammar:3:10: namespace cannot be pass as proc argument: ns"})
}

@(test)
test_import_nonexistent_namespace :: proc(t: ^testing.T) {
	root := scratch_dir(t, "cmd/check/testdata/scratch/import_none")
	defer os.remove_all("cmd/check/testdata/scratch/import_none")
	defer delete(root)

	abs := cat(root, "/main.grammar")
	defer delete(abs)
	src := "ns = @import(\"./nope\");\n"
	files := []Mem_File{{abs = abs, display = "main.grammar", src = src}}
	msgs := run_semantics(files)
	assert_messages(t, msgs, {"main.grammar:1:14: namespace \"./nope\" does not exist"})
}

@(test)
test_import_cycle :: proc(t: ^testing.T) {
	root := scratch_dir(t, "cmd/check/testdata/scratch/cycle")
	defer os.remove_all("cmd/check/testdata/scratch/cycle")
	defer delete(root)

	sub := cat(root, "/sub")
	defer delete(sub)
	os.make_directory_all(sub)
	ag := cat(root, "/a.grammar")
	defer delete(ag)
	write_test_file(t, ag, "nb = @import(\"./sub\");\n")
	sg := cat(sub, "/s.grammar")
	defer delete(sg)
	write_test_file(t, sg, "bb = @import(\"..\");\n")

	cu := new_compilation_unit()
	defer destroy_compilation_unit(&cu)
	load_namespace(&cu, root)
	run_checks(&cu)

	msgs := collect_messages(&cu)
	msg := strings.concatenate(
		{
			"cmd/check/testdata/scratch/cycle/sub/s.grammar:1:1: import cycle detected involving ",
			"cmd/check/testdata/scratch/cycle",
		},
	)
	defer delete(msg)
	assert_messages(t, msgs, {msg})
}

@(test)
test_check_cli_reports_semantic_errors :: proc(t: ^testing.T) {
	ok_dir := "cmd/check/testdata/scratch/cli_ok"
	os.remove_all(ok_dir)
	defer os.remove_all(ok_dir)
	os.make_directory_all(ok_dir)
	ok_main := cat(ok_dir, "/main.grammar")
	defer delete(ok_main)
	write_test_file(t, ok_main, "a = \"x\";\nb = a;\n")

	stderr := bytes.Buffer{}
	bytes.buffer_init(&stderr, {})
	defer bytes.buffer_destroy(&stderr)

	code := check(ok_dir, .Package, bytes.buffer_to_stream(&stderr))
	testing.expect(t, code == 0, "valid package must check clean")
	testing.expect(
		t,
		len(bytes.buffer_to_bytes(&stderr)) == 0,
		"no diagnostics on a valid package",
	)

	bad_dir := "cmd/check/testdata/scratch/cli_bad"
	os.remove_all(bad_dir)
	defer os.remove_all(bad_dir)
	os.make_directory_all(bad_dir)
	bad_good := cat(bad_dir, "/good.grammar")
	defer delete(bad_good)
	write_test_file(t, bad_good, "a = \"x\";\n")
	bad_bad := cat(bad_dir, "/bad.grammar")
	defer delete(bad_bad)
	write_test_file(t, bad_bad, "b = nope;\n")

	bytes.buffer_reset(&stderr)
	code = check(bad_dir, .Package, bytes.buffer_to_stream(&stderr))
	testing.expect(t, code == 1, "package with a semantic error must fail")
	report := strings.clone(string(bytes.buffer_to_bytes(&stderr)))
	defer delete(report)
	testing.expect(
		t,
		strings.contains(report, "bad.grammar:1:5: undefined identifier: nope"),
		"expected the undefined identifier diagnostic",
	)
}
