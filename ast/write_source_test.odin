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

// The branches of an alternative go one to a line, since one line hides them among
// each other. The `|` and the `;` line up one column past the name, which is where
// the formatter puts them (rule 4 of implementation/08-fmt.md).
@(test)
test_write_rule_writes_an_alternative_one_branch_to_a_line :: proc(t: ^testing.T) {
	expect_written(t, "r = a | b | c;", "r", "r = a\n  | b\n  | c\n  ;\n")
}

// The columns follow the name and the parameters the rule is declared with.
@(test)
test_write_rule_lines_up_on_a_name_with_parameters :: proc(t: ^testing.T) {
	expect_written(t, "rule x = a | b;", "rule", "rule x = a\n       | b\n       ;\n")
}

// A body that is not an alternative of branches stays on one line, however long it
// is: there is nothing to choose between, so nothing is gained by a line each.
@(test)
test_write_rule_leaves_a_body_that_is_not_an_alternative_on_one_line :: proc(t: ^testing.T) {
	expect_written(t, "r = a b { c d } [ e ];", "r", "r = a b { c d } [ e ];\n")
	expect_written(t, "r = ( a | b ) c;", "r", "r = ( a | b ) c;\n")
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
		"use = p\n      ( a | b )\n      q\n    ;\n",
		.Strip,
	)
}

// A rule with a leading and no trailing, or a trailing and no leading, is the same
// rule with a part left out, so it loses a line and nothing else.
@(test)
test_write_normalized_rule_writes_one_line_per_part_it_has :: proc(t: ^testing.T) {
	expect_written_normalized(
		t,
		"use = p a q | p b q;",
		"use",
		"use = p\n      ( a | b )\n      q\n    ;\n",
		.Strip,
	)
	expect_written_normalized(
		t,
		"use = p a b | p c d;",
		"use",
		"use = p\n      ( a b | c d )\n    ;\n",
		.Strip,
	)
	expect_written_normalized(
		t,
		"use = a b q | a c q;",
		"use",
		"use = a\n      ( b | c )\n      q\n    ;\n",
		.Strip,
	)
}

// A rule with no leading and no trailing is one part, and stays on one line however
// many branches the choice has.
@(test)
test_write_normalized_rule_leaves_a_choice_with_no_parts_around_it_on_one_line :: proc(
	t: ^testing.T,
) {
	expect_written_normalized(t, "use = a;", "use", "use = a;\n", .Strip)
	expect_written_normalized(t, "use = a | b;", "use", "use = ( a | b );\n", .Strip)
	expect_written_normalized(
		t,
		"use = a | b | c;",
		"use",
		"use = ( a | b | c );\n",
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
		"use = a b\n    | a b c\n    ;\n",
		.Strip,
	)
	expect_written_normalized(
		t,
		"call = p ( a q ) | p;",
		"call",
		"call = p ( a q )\n     | p\n     ;\n",
		.Strip,
	)
}

// A tag two branches give the same production differently, but under different pair
// names, is combined into one run: a production two branches annotate differently
// comes out annotated with both, where the other policies drop all but the first.
@(test)
test_write_normalized_rule_merges_tag_pairs_under_the_merge_policy :: proc(t: ^testing.T) {
	expect_written_normalized(
		t,
		"use = a `kind=\"x\"` | a `name=\"y\"`;",
		"use",
		"use = a `kind=\"x\"; name=\"y\"`;\n",
		.Merge,
	)
	expect_written_normalized(
		t,
		"use = a `kind=\"x\"` | a `name=\"y\"`;",
		"use",
		"use = a;\n",
		.Strip,
	)
	expect_written_normalized(
		t,
		"use = a `kind=\"x\"` | a `name=\"y\"`;",
		"use",
		"use = ( a `kind=\"x\"` | a `name=\"y\"` );\n",
		.Keep,
	)
}

// A pair name cannot carry two values, so the first is kept and the contradiction
// is reported rather than written down as a second pair of the same name.
@(test)
test_write_normalized_rule_keeps_the_first_value_of_a_conflicting_pair :: proc(t: ^testing.T) {
	src := "use = a `kind=\"x\"` | a `kind=\"y\"`;"
	expect_written_normalized(t, src, "use", "use = a `kind=\"x\"`;\n", .Merge)
	expect_written_normalized(t, src, "use", "use = a;\n", .Strip)
	expect_written_normalized(
		t,
		src,
		"use",
		"use = ( a `kind=\"x\"` | a `kind=\"y\"` );\n",
		.Keep,
	)
}

// Merging is what happens instead of the other policies when two branches are one
// branch, so it does not reach an element two branches kept apart: a tagged element
// always closes its branch, so the pairs meet in a whole branch.
@(test)
test_write_normalized_rule_leaves_the_tags_of_two_different_elements_alone :: proc(t: ^testing.T) {
	expect_written_normalized(
		t,
		"use = a b `kind=\"x\"` | a c `name=\"y\"`;",
		"use",
		"use = ( a b `kind=\"x\"` | a c `name=\"y\"` );\n",
		.Merge,
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
// A factored rule written out is a sequence holding a group, and factoring only ever
// looks at alternatives, so the parts it was factored into cannot be read back out of
// it: the second pass writes the same rule as the sequence it now reads as. The third
// pass is the one that settles, which is what `grammar normalize --write` takes.
@(test)
test_write_normalized_rule_settles_after_a_second_pass :: proc(t: ^testing.T) {
	once := write_normalized_text(t, "use = p a q | p b q;", "use", .Strip)
	defer delete(once)
	twice := write_normalized_text(t, once, "use", .Strip)
	defer delete(twice)
	thrice := write_normalized_text(t, twice, "use", .Strip)
	defer delete(thrice)
	testing.expectf(t, twice == thrice, "got %q then %q", twice, thrice)
}

// Settling takes one pass whatever the rule looks like, so it holds for a rule that
// writes as its branches and for one with a nested alternative in it.
@(test)
test_write_normalized_rule_settles_whatever_the_rule_is :: proc(t: ^testing.T) {
	srcs := []string{
		"use = a b | a b c;",
		"use = p a q | p b q;",
		"use = { x a | x b };",
		"use = p ( a | b ) q;",
		"use = a | b | c;",
	}
	for src in srcs {
		once := write_normalized_text(t, src, "use", .Strip)
		defer delete(once)
		twice := write_normalized_text(t, once, "use", .Strip)
		defer delete(twice)
		thrice := write_normalized_text(t, twice, "use", .Strip)
		defer delete(thrice)
		testing.expectf(t, twice == thrice, "%q: got %q then %q", src, twice, thrice)
	}
}

// A nested alternative is factored and written back where it stood, keeping the
// leading and the trailing its own branches shared: they are what the branches had in
// common, so leaving them out would write a language the rule does not match.
@(test)
test_write_normalized_rule_writes_a_nested_group_with_its_parts :: proc(t: ^testing.T) {
	expect_written_normalized(t, "use = { x a | x b };", "use", "use = { x ( a | b ) };\n", .Strip)
	expect_written_normalized(
		t,
		"use = [ x a | x b ];",
		"use",
		"use = [ x ( a | b ) ];\n",
		.Strip,
	)
	// The branches share `q` at the end and nothing at the start, so the group the
	// factored form writes is the middle and `q` is a trailing of the nested
	// production, which has to be written for the rule to mean what it meant.
	expect_written_normalized(
		t,
		"use = x { a q | b q };",
		"use",
		"use = x { ( a | b ) q };\n",
		.Strip,
	)
	expect_written_normalized(
		t,
		"use = x { p a | p b };",
		"use",
		"use = x { p ( a | b ) };\n",
		.Strip,
	)
}

// A nested production with an empty middle has no factored form either, since
// `( | x )` does not parse, so it is written as its branches whole like a rule that
// has one. The branches keep the leading and the trailing they were factored around.
@(test)
test_write_normalized_rule_writes_a_nested_empty_middle_as_its_branches :: proc(t: ^testing.T) {
	expect_written_normalized(
		t,
		"use = { x a q | x a };",
		"use",
		"use = { x a q | x a };\n",
		.Strip,
	)
	expect_written_normalized(
		t,
		"use = [ p a q | p a ];",
		"use",
		"use = [ p a q | p a ];\n",
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
