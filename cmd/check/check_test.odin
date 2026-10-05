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
// runs the binding and type-checking phases, and returns the *errors* as
// "path:line:col: message" strings. Warnings are reported separately by
// run_warnings, so a test that cares only about errors does not have to list
// them. The returned strings are owned by the caller; the compilation unit is
// destroyed.
run_semantics :: proc(files: []Mem_File) -> [dynamic]string {
	cu := new_compilation_unit()
	defer destroy_compilation_unit(&cu)

	for f in files {
		load_source(&cu, strings.clone(f.abs), strings.clone(f.display), f.src)
	}
	run_checks(&cu)
	return collect_messages(&cu)
}

// run_warnings is run_semantics for the warnings, formatted the way `grammar
// check` prints them: "path:line:col: warning: message".
run_warnings :: proc(files: []Mem_File) -> [dynamic]string {
	cu := new_compilation_unit()
	defer destroy_compilation_unit(&cu)

	for f in files {
		load_source(&cu, strings.clone(f.abs), strings.clone(f.display), f.src)
	}
	run_checks(&cu)
	return collect_diagnostics(&cu, .Warning)
}

// collect_messages formats every error diagnostic in cu as
// "path:line:col: message", sorted by path, line and column. The returned
// strings are owned by the caller.
collect_messages :: proc(cu: ^Compilation_Unit) -> [dynamic]string {
	return collect_diagnostics(cu, .Error)
}

// collect_diagnostics formats every diagnostic of the given severity in cu,
// sorted by path, line and column, and returns the strings owned by the caller.
collect_diagnostics :: proc(cu: ^Compilation_Unit, severity: Severity) -> [dynamic]string {
	messages := make([dynamic]string, len(cu.errors))
	for e, i in cu.errors {
		if e.severity != severity do continue
		b := strings.builder_make()
		strings.write_string(&b, e.path)
		strings.write_rune(&b, ':')
		strings.write_int(&b, e.line)
		strings.write_rune(&b, ':')
		strings.write_int(&b, e.col)
		strings.write_string(&b, ": ")
		if severity == .Warning {
			strings.write_string(&b, "warning: ")
		}
		strings.write_string(&b, e.message)
		messages[i] = strings.clone(strings.to_string(b))
		strings.builder_destroy(&b)
	}
	// Entries skipped by the severity filter are left as empty strings; drop them
	// so the result holds exactly the matching diagnostics.
	n := 0
	for m in messages {
		if m == "" do continue
		messages[n] = m
		n += 1
	}
	resize(&messages, n)
	sort.quick_sort_proc(messages[:], cmp_string)
	return messages
}

// assert_messages checks that got matches the expected diagnostics.
assert_messages :: proc(t: ^testing.T, got: [dynamic]string, want: []string) {
	assert_diagnostics(t, got, want)
}

// assert_warnings checks the warnings reported for the given files.
assert_warnings :: proc(t: ^testing.T, files: []Mem_File, want: []string) {
	assert_diagnostics(t, run_warnings(files), want)
}

assert_diagnostics :: proc(t: ^testing.T, got: [dynamic]string, want: []string) {
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

// A comment inside a rule body is trivia, so it must not resolve as a name, count
// as a call argument, or hide the rule it sits in.
@(test)
test_comments_inside_rule_body_are_ignored :: proc(t: ^testing.T) {
	src :=
		"a = \"x\";\n" +
		"// b is documented here\n" +
		"b = a // use a\n" +
		"  | a a // twice\n" +
		"  ; // end\n" +
		"p x = x;\n" +
		"c = <p a // one arg\n" +
		"    >;\n"
	assert_messages(t, run_semantics([]Mem_File{test_src(t, "comments", "main.grammar", src)}), {})
}

// A tag annotates a production, so it changes nothing about which operands the
// rule produces: a tagged element resolves, is passed, and expands as usual. It
// is written outside a repetition, an optional or a group, since it annotates a
// whole production.
@(test)
test_tagged_expressions_are_checked_like_their_element :: proc(t: ^testing.T) {
	src :=
		"a = \"x\";\n" +
		"b = a `name=\"b\"`;\n" +
		"p x = x;\n" +
		"c = <p a> `name=\"c\"`;\n" +
		"d = a b `name=\"d\"`;\n" +
		"e = { a } `name=\"e\"`;\n" +
		"f = [ a ] `name=\"f\"`;\n" +
		"g = a | b `name=\"g\"`;\n" +
		"h = a a a `name=\"h\"`;\n" +// A tag over a longer sequence must check every element of it.
		"i = a a `name=\"i\"`\n" +
		"  | a\n" +
		"  ;\n" +
		"j x = x x `name=\"j\"`;\n" +// A param used only by a tagged element is still used.
		"k = <j a> `name=\"k\"`;\n"
	assert_messages(t, run_semantics([]Mem_File{test_src(t, "tags", "main.grammar", src)}), {})
}

// A tag does not make its production resolvable on its own: every element of an
// annotated sequence is still resolved.
@(test)
test_tagged_sequence_still_resolves_each_element :: proc(t: ^testing.T) {
	src := "a = \"x\";\nb = a missing `name=\"b\"`;\n"
	assert_messages(
		t,
		run_semantics([]Mem_File{test_src(t, "tag_resolve", "main.grammar", src)}),
		{"main.grammar:2:7: undefined identifier: missing"},
	)
}

// A tag inside a repetition, an optional, a group or a call annotates an element
// that is not the last of its production, so the parser rejects it there.
@(test)
test_tag_inside_a_nested_production_is_rejected :: proc(t: ^testing.T) {
	src := "a = \"x\";\n" + "e = { a `name=\"e\"` };\n"
	assert_messages(
		t,
		run_semantics([]Mem_File{test_src(t, "tag_nested", "main.grammar", src)}),
		{"main.grammar:2:10: a tag may not appear inside a group, repetition, optional or call"},
	)
}

// A production is annotated once, so a second tag is rejected.
@(test)
test_two_tags_on_one_production_is_rejected :: proc(t: ^testing.T) {
	src := "a = \"x\";\nb = a a `name=\"a\"` `age=\"100\"`;\n"
	assert_messages(
		t,
		run_semantics([]Mem_File{test_src(t, "tag_two", "main.grammar", src)}),
		{"main.grammar:2:20: a production may carry only one tag"},
	)
}

@(test)
test_undefined_identifier :: proc(t: ^testing.T) {
	src := "a = \"x\";\nb = c;\n"
	msgs := run_semantics([]Mem_File{test_src(t, "undef", "main.grammar", src)})
	assert_messages(t, msgs, {"main.grammar:2:5: undefined identifier: c"})
}

@(test)
test_private_rule_visible_only_in_its_file :: proc(t: ^testing.T) {
	// `_axe` is a private rule declared in a.grammar; b.grammar in the same
	// namespace cannot see it.
	files := []Mem_File {
		test_src(t, "privates", "a.grammar", "_axe = \"x\";\n"),
		test_src(t, "privates", "b.grammar", "use = _axe;\n"),
	}
	msgs := run_semantics(files)
	assert_messages(t, msgs, {"b.grammar:1:7: undefined identifier: _axe"})
}

@(test)
test_lowercase_rule_is_shared_across_files :: proc(t: ^testing.T) {
	// Only an underscore prefix makes a rule private; a lowercase name declares
	// a local rule, which is shared across the files of its namespace.
	files := []Mem_File {
		test_src(t, "shared", "a.grammar", "expr = \"x\";\n"),
		test_src(t, "shared", "b.grammar", "use = expr;\n"),
	}
	assert_messages(t, run_semantics(files), {})
}

@(test)
test_private_rules_do_not_collide_across_files :: proc(t: ^testing.T) {
	// Two files may each declare a private rule with the same name.
	files := []Mem_File {
		test_src(t, "collide", "a.grammar", "_item = \"a\";\n"),
		test_src(t, "collide", "b.grammar", "_item = \"b\";\n"),
	}
	assert_messages(t, run_semantics(files), {})
}

@(test)
test_malformed_private_rule_names :: proc(t: ^testing.T) {
	// A bare `_` and a name whose second character is not a letter are both
	// rejected. `__c` is no longer malformed-private territory: a "__" prefix
	// followed by a letter scans as an external, so it cannot name a rule at
	// all. The malformed rule is still registered in the namespace so the rest
	// of the file keeps resolving.
	src := "_ = \"a\";\n_1b = \"b\";\n__1c = \"c\";\nd = _;\n"
	msgs := run_semantics([]Mem_File{test_src(t, "badprivate", "main.grammar", src)})
	assert_messages(
		t,
		msgs,
		{
			"main.grammar:1:1: malformed private rule name _. a private rule name is an underscore followed by a letter, as in _helper",
			"main.grammar:2:1: malformed private rule name _1b. a private rule name is an underscore followed by a letter, as in _helper",
			"main.grammar:3:1: malformed private rule name __1c. a private rule name is an underscore followed by a letter, as in _helper",
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
test_local_rule_is_not_reachable_from_another_namespace :: proc(t: ^testing.T) {
	root := scratch_dir(t, "cmd/check/testdata/scratch/xns_local")
	defer os.remove_all("cmd/check/testdata/scratch/xns_local")
	defer delete(root)

	base := cat(root, "/base")
	defer delete(base)
	os.make_directory_all(base)
	rgram := cat(base, "/r.grammar")
	defer delete(rgram)
	// `helper` is a local rule of `base`: it is in the namespace, but not
	// exported, so another namespace cannot reach it.
	write_test_file(t, rgram, "helper = \"x\";\nExported = \"y\";\n")

	abs := cat(root, "/main.grammar")
	defer delete(abs)
	src := "ns = @import(\"./base\");\nA = ns.helper;\n"
	files := []Mem_File{{abs = abs, display = "main.grammar", src = src}}
	assert_messages(
		t,
		run_semantics(files),
		{
			"main.grammar:2:8: ns.helper is not exported. only a rule whose name starts with an uppercase letter is accessible from another namespace",
		},
	)
	// The rejected member access does not count as a use, but `helper` is a
	// local rule that nothing else names either, so it is still reported.
	assert_warnings(
		t,
		files,
		{
			"cmd/check/testdata/scratch/xns_local/base/r.grammar:1:1: warning: unused local rule: helper",
		},
	)
}

@(test)
test_exported_rule_is_reachable_from_another_namespace :: proc(t: ^testing.T) {
	root := scratch_dir(t, "cmd/check/testdata/scratch/xns_exported")
	defer os.remove_all("cmd/check/testdata/scratch/xns_exported")
	defer delete(root)

	base := cat(root, "/base")
	defer delete(base)
	os.make_directory_all(base)
	rgram := cat(base, "/r.grammar")
	defer delete(rgram)
	write_test_file(t, rgram, "Exported = \"x\";\n")

	abs := cat(root, "/main.grammar")
	defer delete(abs)
	src := "ns = @import(\"./base\");\nA = ns.Exported;\n"
	files := []Mem_File{{abs = abs, display = "main.grammar", src = src}}
	assert_messages(t, run_semantics(files), {})
	assert_warnings(t, files, {})
}

@(test)
test_unused_proc_parameter :: proc(t: ^testing.T) {
	// `N` is exported, so the parameter is the only thing to report.
	src := "N x y = x;\n"
	files := []Mem_File{test_src(t, "unusedparam", "main.grammar", src)}
	msgs := run_semantics(files)
	assert_messages(t, msgs, {"main.grammar:1:5: unused proc parameter: y"})
	// An unused parameter is an error, not one of the unused warnings: it fails
	// the run rather than being advisory.
	assert_warnings(t, files, {})
}

@(test)
test_proc_parameter_as_call_argument_counts_as_used :: proc(t: ^testing.T) {
	// `N` is exported, so the parameter is the only thing to report.
	src := "N x = <fn x>;\nfn a = a;"
	files := []Mem_File{test_src(t, "param_in_call_argument", "main.grammar", src)}
	msgs := run_semantics(files)
	assert_messages(t, msgs, {})
	assert_warnings(t, files, {})
}

@(test)
test_unused_private_rule_warns :: proc(t: ^testing.T) {
	src := "_used = \"x\";\n_unused = \"y\";\nA = _used;\n"
	files := []Mem_File{test_src(t, "warnpriv", "main.grammar", src)}
	assert_messages(t, run_semantics(files), {})
	assert_warnings(t, files, {"main.grammar:2:1: warning: unused private rule: _unused"})
}

@(test)
test_private_rule_referencing_only_itself_warns :: proc(t: ^testing.T) {
	// Reachability is judged by whether another rule names it, so a rule that
	// only feeds itself is still dead.
	src := "_loop = _loop \"x\";\nA = \"y\";\n"
	files := []Mem_File{test_src(t, "warnself", "main.grammar", src)}
	assert_warnings(t, files, {"main.grammar:1:1: warning: unused private rule: _loop"})
}

@(test)
test_unused_local_rule_warns :: proc(t: ^testing.T) {
	src := "used = \"x\";\nunused = \"y\";\nA = used;\n"
	files := []Mem_File{test_src(t, "warnlocal", "main.grammar", src)}
	assert_messages(t, run_semantics(files), {})
	assert_warnings(t, files, {"main.grammar:2:1: warning: unused local rule: unused"})
}

@(test)
test_local_rule_used_from_a_sibling_file_does_not_warn :: proc(t: ^testing.T) {
	// A local rule is shared across its namespace, so a reference from any file
	// in that namespace counts.
	files := []Mem_File {
		test_src(t, "warnlocalns", "a.grammar", "helper = \"x\";\n"),
		test_src(t, "warnlocalns", "b.grammar", "A = helper;\n"),
	}
	assert_warnings(t, files, {})
}

@(test)
test_local_rules_used_only_by_each_other_do_not_warn :: proc(t: ^testing.T) {
	// Each of these is named by the other, so both count as used. Reachability
	// is judged by direct references, not by a search for an entry point, so a
	// mutually recursive pair of local rules is not reported. A rule that only
	// ever names *itself* is reported; see the self-reference test above.
	src := "ping = pong;\npong = ping;\n"
	files := []Mem_File{test_src(t, "warncycle", "main.grammar", src)}
	assert_warnings(t, files, {})
}

@(test)
test_exported_rule_is_never_reported_unused :: proc(t: ^testing.T) {
	// Nothing inside this namespace references Exported, but an importing
	// namespace may, so it is never reported.
	src := "Exported = \"x\";\n_helper = \"y\";\n"
	files := []Mem_File{test_src(t, "warnexport", "main.grammar", src)}
	assert_warnings(t, files, {"main.grammar:2:1: warning: unused private rule: _helper"})
}

@(test)
test_unused_binding_warns :: proc(t: ^testing.T) {
	root := scratch_dir(t, "cmd/check/testdata/scratch/warn_bind_unused")
	defer os.remove_all("cmd/check/testdata/scratch/warn_bind_unused")
	defer delete(root)

	base := cat(root, "/base")
	defer delete(base)
	os.make_directory_all(base)
	rgram := cat(base, "/r.grammar")
	defer delete(rgram)
	write_test_file(t, rgram, "R = \"x\";\n")

	abs := cat(root, "/main.grammar")
	defer delete(abs)
	// `unused` is imported but never named; `used` is named by a member access.
	src := "unused = @import(\"./base\");\nused = @import(\"./base\");\nA = used.R;\n"
	files := []Mem_File{{abs = abs, display = "main.grammar", src = src}}
	assert_messages(t, run_semantics(files), {})
	assert_warnings(t, files, {"main.grammar:1:1: warning: unused binding: unused"})
}

@(test)
test_binding_named_without_a_member_access_does_not_warn :: proc(t: ^testing.T) {
	root := scratch_dir(t, "cmd/check/testdata/scratch/warn_bind_bare")
	defer os.remove_all("cmd/check/testdata/scratch/warn_bind_bare")
	defer delete(root)

	base := cat(root, "/base")
	defer delete(base)
	os.make_directory_all(base)
	rgram := cat(base, "/r.grammar")
	defer delete(rgram)
	write_test_file(t, rgram, "R = \"x\";\n")

	abs := cat(root, "/main.grammar")
	defer delete(abs)
	src := "ns = @import(\"./base\");\np x = ns;\nA = <p ns>;\n"
	files := []Mem_File{{abs = abs, display = "main.grammar", src = src}}
	assert_warnings(t, files, {})
}

@(test)
test_imported_namespace_rule_used_from_another_namespace_does_not_warn :: proc(t: ^testing.T) {
	// The use crosses a namespace boundary, which a bare ident could not do.
	// Counting it keeps the exported rule out of the unused report either way,
	// and the local rule in `base` honest about who names it.
	root := scratch_dir(t, "cmd/check/testdata/scratch/warn_bind_xns")
	defer os.remove_all("cmd/check/testdata/scratch/warn_bind_xns")
	defer delete(root)

	base := cat(root, "/base")
	defer delete(base)
	os.make_directory_all(base)
	rgram := cat(base, "/r.grammar")
	defer delete(rgram)
	write_test_file(t, rgram, "R = \"x\";\n")

	abs := cat(root, "/main.grammar")
	defer delete(abs)
	src := "ns = @import(\"./base\");\nA = ns.R;\n"
	files := []Mem_File{{abs = abs, display = "main.grammar", src = src}}
	assert_warnings(t, files, {})
}

@(test)
test_unused_is_not_reported_for_a_shadowed_redeclaration :: proc(t: ^testing.T) {
	// Only the declaration that won the redeclaration contest is registered, so
	// only that one can be reported unused. Warning about the rejected duplicate
	// too would restate an error the checker has already given.
	src := "dup = \"a\";\ndup = \"b\";\nA = dup;\n"
	files := []Mem_File{test_src(t, "warnshadow", "main.grammar", src)}
	assert_messages(
		t,
		run_semantics(files),
		{
			"main.grammar:2:1: field dup redeclared in this namespace. (see other declaration at main.grammar:1:1)",
		},
	)
	assert_warnings(t, files, {})
}

@(test)
test_warnings_are_suppressed_for_a_broken_file :: proc(t: ^testing.T) {
	// A file that failed to parse has no trustworthy rule list, so it reports
	// its errors and stays quiet about unused declarations.
	src := "unused = \"x\";\n_unused = \"y\"\n"
	files := []Mem_File{test_src(t, "warnbroken", "main.grammar", src)}
	assert_warnings(t, files, {})
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
	ok_dir := "cmd/check/testdata/cli_scratch_ok"
	os.remove_all(ok_dir)
	defer os.remove_all(ok_dir)
	os.make_directory_all(ok_dir)
	ok_main := cat(ok_dir, "/main.grammar")
	defer delete(ok_main)
	// Exported rules are never reported unused, so this package has nothing to
	// say: no errors and no warnings.
	write_test_file(t, ok_main, "A = \"x\";\nB = A;\n")

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

	bad_dir := "cmd/check/testdata/cli_scratch_bad"
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

@(test)
test_check_cli_warnings_do_not_fail_the_run :: proc(t: ^testing.T) {
	warn_dir := "cmd/check/testdata/cli_scratch_warn"
	os.remove_all(warn_dir)
	defer os.remove_all(warn_dir)
	os.make_directory_all(warn_dir)
	warn_main := cat(warn_dir, "/main.grammar")
	defer delete(warn_main)
	// `unused` is a local rule that nothing references, and `_gone` a private
	// one: both warn, neither is an error.
	write_test_file(t, warn_main, "unused = \"x\";\nA = \"y\";\n_gone = \"z\";\n")

	stderr := bytes.Buffer{}
	bytes.buffer_init(&stderr, {})
	defer bytes.buffer_destroy(&stderr)

	code := check(warn_dir, .Package, bytes.buffer_to_stream(&stderr))
	report := strings.clone(string(bytes.buffer_to_bytes(&stderr)))
	defer delete(report)

	testing.expect(t, code == 0, "warnings alone must not make the run fail")
	testing.expect(
		t,
		strings.contains(report, "main.grammar:1:1: warning: unused local rule: unused"),
		"expected the unused local rule warning",
	)
	testing.expect(
		t,
		strings.contains(report, "main.grammar:3:1: warning: unused private rule: _gone"),
		"expected the unused private rule warning",
	)
}
