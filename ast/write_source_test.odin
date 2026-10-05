package ast

import "core:bytes"
import "core:strings"
import "core:testing"

import "../token"

// parse_source parses src, which has to be well formed, and returns the file that
// owns it together with the rules it declares. Both belong to the caller: the file
// has to outlive anything built from its rules, since a rule shares the arrays and
// the source views the file holds.
parse_source :: proc(t: ^testing.T, src: string) -> (file: File, rules: [dynamic]Rule) {
	tokens, lex_errors := token.scan(src)
	defer delete(tokens)
	defer delete(lex_errors)
	testing.expectf(t, len(lex_errors) == 0, "unexpected token errors for %q", src)

	parsed, parse_errors := parse_file(src, tokens[:])
	defer delete(parse_errors)
	testing.expectf(t, len(parse_errors) == 0, "unexpected parse errors for %q", src)

	rules = make([dynamic]Rule)
	for decl in parsed.decls {
		rule := decl.(Rule) or_continue
		append(&rules, rule)
	}
	return parsed, rules
}

// find_rule returns the rule named name, failing the test when the fixture does not
// declare it.
find_rule :: proc(t: ^testing.T, rules: [dynamic]Rule, name: string) -> Rule {
	for rule in rules {
		if rule.ident.name == name do return rule
	}
	testing.fail_now(t, strings.concatenate({"the fixture declares no rule named ", name}))
}

// write_rule_text expands the rule named name in src and writes it out. The
// returned string is owned by the caller.
write_rule_text :: proc(t: ^testing.T, src, name: string) -> string {
	file, rules := parse_source(t, src)
	defer destroy_file(&file)
	defer delete(rules)

	scope := Build_Scope(rules[:])
	defer Destroy_Scope(&scope)

	buf: bytes.Buffer
	bytes.buffer_init(&buf, {})
	defer bytes.buffer_destroy(&buf)

	expanded, _ := expand_rule(find_rule(t, rules, name), &scope)
	defer destroy_rule(&expanded)
	Write_Rule(bytes.buffer_to_stream(&buf), expanded)

	return strings.clone(bytes.buffer_to_string(&buf))
}

// write_normalized_text factors the rule named name in src and writes it out. The
// returned string is owned by the caller.
write_normalized_text :: proc(
	t: ^testing.T,
	src, name: string,
	tags: Tag_Policy,
) -> string {
	file, rules := parse_source(t, src)
	defer destroy_file(&file)
	defer delete(rules)

	scope := Build_Scope(rules[:])
	defer Destroy_Scope(&scope)

	opts := Normalize_Options{tags = tags}
	defer destroy_normalize_options(&opts)

	normalized, _ := normalize_rule(find_rule(t, rules, name), &scope, &opts)
	defer destroy_normalized_rule(&normalized)

	buf: bytes.Buffer
	bytes.buffer_init(&buf, {})
	defer bytes.buffer_destroy(&buf)
	Write_Normalized_Rule(bytes.buffer_to_stream(&buf), normalized)

	return strings.clone(bytes.buffer_to_string(&buf))
}

// normalized_rule_of factors the named rule and hands the tree back, so that a test
// can ask something of the form as well as of its text.
normalized_rule_of :: proc(
	t: ^testing.T,
	src, name: string,
	tags: Tag_Policy,
) -> (file: File, rules: [dynamic]Rule, scope: Scope, normalized: Normalized_Rule) {
	file, rules = parse_source(t, src)
	scope = Build_Scope(rules[:])
	rule := find_rule(t, rules, name)
	normalized, _ = normalize_rule(rule, &scope, &Normalize_Options{tags = tags})
	return
}

// expect_written fails the test unless writing the named rule of src gives want.
expect_written :: proc(t: ^testing.T, src, name, want: string) {
	got := write_rule_text(t, src, name)
	defer delete(got)
	testing.expectf(t, got == want, "got %q, want %q", got, want)
}

// expect_written_normalized fails the test unless factoring the named rule of src
// under the given tag policy gives want.
expect_written_normalized :: proc(
	t: ^testing.T,
	src, name, want: string,
	tags: Tag_Policy,
) {
	got := write_normalized_text(t, src, name, tags)
	defer delete(got)
	testing.expectf(t, got == want, "got %q, want %q", got, want)
}

// Every kind of production is written back the way the formatter spells it, so that
// a rule with no call in it survives a round trip.
@(test)
test_write_rule_writes_every_production_kind :: proc(t: ^testing.T) {
	expect_written(
		t,
		"r = ident ( a b ) [ c ] { d e } <p a \"b\"> __ext__ q.s 're' `t=\"v\"; u=\"w\"`;",
		"r",
		"r = ident ( a b ) [ c ] { d e } <p a \"b\"> __ext__ q.s 're' `t=\"v\"; u=\"w\"`;\n",
	)
}

@(test)
test_write_rule_writes_an_external_with_its_underscores :: proc(t: ^testing.T) {
	expect_written(t, "r = __ext;", "r", "r = __ext__;\n")
}

@(test)
test_write_rule_keeps_the_parameters_it_declares :: proc(t: ^testing.T) {
	expect_written(t, "p x y = x y;", "p", "p x y = x y;\n")
}

@(test)
test_write_rule_writes_an_alternative_with_pipes :: proc(t: ^testing.T) {
	expect_written(t, "r = a | b | c;", "r", "r = a | b | c;\n")
}

// A rule with no call in it comes back as it stands, which is what makes
// `grammar expand -w` a no-op on a file that has nothing to expand.
@(test)
test_write_rule_round_trips_a_rule_with_no_call :: proc(t: ^testing.T) {
	expect_written(t, "a = \"x\" | \"y\";\nb = a { a };\n", "b", "b = a { a };\n")
}

// A call the expansion could not resolve is written the way it was spelled.
@(test)
test_write_rule_writes_an_unexpanded_call :: proc(t: ^testing.T) {
	expect_written(t, "r = <nope \"a\">;", "r", "r = <nope \"a\">;\n")
}

// The factored rule is written as its leading, a group holding the middles, and its
// trailing. The group is what makes it mean what the branches it came from meant.
@(test)
test_write_normalized_rule_writes_leading_a_group_and_trailing :: proc(t: ^testing.T) {
	expect_written_normalized(
		t,
		"use = p a q | p b q;",
		"use",
		"use = p ( a | b ) q;\n",
		.Strip,
	)
}

@(test)
test_write_normalized_rule_leaves_a_single_middle_ungrouped :: proc(t: ^testing.T) {
	expect_written_normalized(t, "use = a b;", "use", "use = a b;\n", .Strip)
}

// An empty middle has no source form: the factored form would be `( | c )`, which
// does not parse. Such a rule is written as its branches whole instead, which is
// what it says, since dropping the branch would leave out a language it matches.
@(test)
test_write_normalized_rule_writes_branches_when_a_middle_is_empty :: proc(t: ^testing.T) {
	expect_written_normalized(
		t,
		"use = a b | a b c;",
		"use",
		"use = a b | a b c;\n",
		.Strip,
	)
	expect_written_normalized(
		t,
		"call = p ( a q ) | p;",
		"call",
		"call = p ( a q ) | p;\n",
		.Strip,
	)
}

@(test)
test_has_empty_middle_reports_a_branch_the_leading_matched :: proc(t: ^testing.T) {
	file, rules, scope, normalized := normalized_rule_of(t, "use = a b | a b c;", "use", .Strip)
	defer destroy_normalized_rule(&normalized)
	defer Destroy_Scope(&scope)
	defer destroy_file(&file)
	defer delete(rules)

	testing.expect(t, Has_Empty_Middle(normalized), "the first branch has no middle")
}

@(test)
test_has_empty_middle_is_false_without_one :: proc(t: ^testing.T) {
	file, rules, scope, normalized := normalized_rule_of(t, "use = a b | a c;", "use", .Strip)
	defer destroy_normalized_rule(&normalized)
	defer Destroy_Scope(&scope)
	defer destroy_file(&file)
	defer delete(rules)

	testing.expect(t, !Has_Empty_Middle(normalized), "both branches have a middle")
}

// A rule that survives factoring unchanged writes back as it stands, so normalizing
// is idempotent on anything without an empty middle.
@(test)
test_write_normalized_rule_is_idempotent :: proc(t: ^testing.T) {
	once := write_normalized_text(t, "use = p a q | p b q;", "use", .Strip)
	defer delete(once)
	twice := write_normalized_text(t, once, "use", .Strip)
	defer delete(twice)
	testing.expectf(t, once == twice, "got %q then %q", once, twice)
}

// A nested alternative is factored and written back as a group where it stood.
@(test)
test_write_normalized_rule_writes_a_nested_group :: proc(t: ^testing.T) {
	expect_written_normalized(t, "use = { x a | x b };", "use", "use = { ( a | b ) };\n", .Strip)
	expect_written_normalized(
		t,
		"use = [ x a | x b ];",
		"use",
		"use = [ ( a | b ) ];\n",
		.Strip,
	)
}

// Under .Keep a tag survives, written where it closes the production it names.
@(test)
test_write_normalized_rule_writes_a_kept_tag :: proc(t: ^testing.T) {
	expect_written_normalized(
		t,
		"use = p a `n=\"1\"` | p b;",
		"use",
		"use = ( p a `n=\"1\"` | p b );\n",
		.Keep,
	)
}

// Under the default the tag goes, so the production it named is written bare.
@(test)
test_write_normalized_rule_drops_a_tag_by_default :: proc(t: ^testing.T) {
	expect_written_normalized(
		t,
		"use = p a `n=\"1\"` | p b;",
		"use",
		"use = ( p a | p b );\n",
		.Strip,
	)
}

// A binding has no body, so it is written back as it stands.
@(test)
test_write_binding_round_trips :: proc(t: ^testing.T) {
	buf: bytes.Buffer
	bytes.buffer_init(&buf, {})
	defer bytes.buffer_destroy(&buf)

	Write_Binding(
		bytes.buffer_to_stream(&buf),
		Binding {
			ident = Ident{name = "f"},
			path  = String_Lit{value = "\"base\""},
		},
	)
	got := strings.clone(bytes.buffer_to_string(&buf))
	defer delete(got)
	testing.expect(t, got == "f = @import(\"base\");\n", got)
}

// A comment on a line of its own is a declaration of its own, so it survives the
// trip through the tree. A comment the scanner kept its break on is written as it
// stands; one that lost it still ends its line.
@(test)
test_write_comment_group_round_trips :: proc(t: ^testing.T) {
	buf: bytes.Buffer
	bytes.buffer_init(&buf, {})
	defer bytes.buffer_destroy(&buf)

	group := Comment_Group{}
	group.list = make([dynamic]Comment)
	append(&group.list, Comment{text = "// one"})
	append(&group.list, Comment{text = "// two\n"})
	defer delete(group.list)
	Write_Comment_Group(bytes.buffer_to_stream(&buf), group)
	got := strings.clone(bytes.buffer_to_string(&buf))
	defer delete(got)
	testing.expect(t, got == "// one\n// two\n", got)
}
