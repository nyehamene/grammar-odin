package ast

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import "../token"

@(test)
test_parse_hello :: proc(t: ^testing.T) {
	file := must_parse(t, `greeting = "Hello" | "Hi";`)
	defer destroy_file(&file)

	testing.expect(t, len(file.decls) == 1, "expected one decl")

	rule, ok := file.decls[0].(Rule)
	testing.expect(t, ok, "expected Rule")
	testing.expect(t, rule.ident.name == "greeting", "wrong rule name")
	testing.expect(t, len(rule.params) == 0, "no parameters expected")

	alts, ok3 := rule.production.(Alternative)
	testing.expect(t, ok3, "expected Alternative")
	branches := collect_branches(alts)
	defer delete(branches)
	testing.expect(t, len(branches) == 2, "expected two alternatives")

	s1, ok4 := branches[0].(String_Lit)
	testing.expect(t, ok4, "first alt should be String_Lit")
	testing.expect(t, s1.value == `"Hello"`, "wrong value for first alt")
	s2, ok5 := branches[1].(String_Lit)
	testing.expect(t, ok5, "second alt should be String_Lit")
	testing.expect(t, s2.value == `"Hi"`, "wrong value for second alt")
}

// An alternative is a chain of choices leaning left, so `a | b | c` is
// `( a | b ) | c` and the branches are read back by walking the left spine. A
// branch in parentheses is a group, so it never looks like part of the chain.
@(test)
test_parse_alternative_is_a_left_leaning_chain :: proc(t: ^testing.T) {
	file := must_parse(t, `r = a | b | c;`)
	defer destroy_file(&file)

	rule := must_rule(t, file, "r")
	outer, ok := rule.production.(Alternative)
	testing.expect(t, ok, "expected Alternative")

	inner, is_chain := outer.lhs^.(Alternative)
	testing.expect(t, is_chain, "the left of the chain is the first two branches")
	_, still_chain := inner.lhs^.(Alternative)
	testing.expect(t, !still_chain, "two branches is the end of the chain")

	branches := collect_branches(outer)
	defer delete(branches)
	testing.expect(t, len(branches) == 3, "expected three branches")

	names := make([dynamic]string, 0, len(branches))
	defer delete(names)
	for branch in branches {
		ident, is_ident := branch.(Ident)
		testing.expect(t, is_ident, "every branch is an identifier here")
		append(&names, ident.name)
	}
	testing.expect(
		t,
		names[0] == "a" && names[1] == "b" && names[2] == "c",
		"the branches come back in the order they were written",
	)
}

@(test)
test_parse_sequence :: proc(t: ^testing.T) {
	file := must_parse(t, `rule = greeting " World";`)
	defer destroy_file(&file)

	rule, _ := file.decls[0].(Rule)
	seq, ok := rule.production.(Sequence)
	testing.expect(t, ok, "expected Sequence")
	testing.expect(t, len(seq.productions) == 2, "expected two elements")

	ident, ok2 := seq.productions[0].(Ident)
	testing.expect(t, ok2, "first element should be Ident")
	testing.expect(t, ident.name == "greeting", "wrong ident name")
}

@(test)
test_parse_binding :: proc(t: ^testing.T) {
	file := must_parse(t, `f = @import("../foo");`)
	defer destroy_file(&file)

	binding, ok := file.decls[0].(Binding)
	testing.expect(t, ok, "expected Binding")
	testing.expect(t, binding.ident.name == "f", "wrong binding name")
	testing.expect(t, binding.path.value == `"../foo"`, "wrong import path")
}

@(test)
test_parse_rule_with_params :: proc(t: ^testing.T) {
	file := must_parse(t, `greet name title = "hello" name title;`)
	defer destroy_file(&file)

	rule, _ := file.decls[0].(Rule)
	testing.expect(t, len(rule.params) == 2, "expected two parameters")
	testing.expect(t, rule.params[0].name == "name", "wrong first param")
	testing.expect(t, rule.params[1].name == "title", "wrong second param")
}

@(test)
test_parse_call :: proc(t: ^testing.T) {
	file := must_parse(t, `fancy = <greet person "Mr">;`)
	defer destroy_file(&file)

	rule, _ := file.decls[0].(Rule)
	call, ok := rule.production.(^Call)
	testing.expect(t, ok, "expected Call")

	ident, i_ok := call.ident.(Ident)
	testing.expect(t, i_ok, "expected the callee to be an Ident")

	testing.expect(t, ident.name == "greet", "wrong callee")
	testing.expect(t, len(call.args) == 2, "expected two arguments")

	arg0, _ := call.args[0].(Ident)
	testing.expect(t, arg0.name == "person", "wrong first argument")
	arg1, _ := call.args[1].(String_Lit)
	testing.expect(t, arg1.value == `"Mr"`, "wrong second argument")
}

@(test)
test_parse_member_access :: proc(t: ^testing.T) {
	file := must_parse(t, `m = foo.bar;`)
	defer destroy_file(&file)

	rule, _ := file.decls[0].(Rule)
	ident, ok := rule.production.(Qual_Ident)
	testing.expect(t, ok, "expected Qual_Ident")
	testing.expect(t, ident.lhs.name == "foo", "inner member should be foo")
	testing.expect(t, ident.rhs.name == "bar", "outer member should be bar")
}

@(test)
test_parse_comments :: proc(t: ^testing.T) {
	file := must_parse(t, "// hi\nrule = \"a\";\n")
	defer destroy_file(&file)

	comments, ok := file.decls[0].(Comment_Group)
	testing.expect(t, ok, "expected Comment_Group first")
	testing.expect(t, strings.contains(comments.list[0].text, "hi"), "comment text preserved")
	_, ok = file.decls[1].(Rule)
	testing.expect(t, ok, "expected Rule after comment")
}

// A comment inside a rule body is trivia: it may sit between any two tokens of
// the declaration, so the rule still parses and its body keeps every element.
@(test)
test_parse_comments_inside_rule_body :: proc(t: ^testing.T) {
	src := `rule1 = a // comment
      | b // comment
      ;

rule2 = a // comment
      ;
`
	file := must_parse(t, src)
	defer destroy_file(&file)

	testing.expect(t, len(file.decls) == 2, "expected two rule declarations")

	rule1, ok := file.decls[0].(Rule)
	testing.expect(t, ok, "expected Rule for rule1")
	testing.expect(t, rule1.ident.name == "rule1", "wrong rule1 name")

	// Both alternatives survive the trailing comments.
	alt, ok3 := rule1.production.(Alternative)
	testing.expect(t, ok3, "expected Alternative for rule1")
	branches := collect_branches(alt)
	defer delete(branches)
	testing.expect(t, len(branches) == 2, "expected two alternatives")

	rule2, ok4 := file.decls[1].(Rule)
	testing.expect(t, ok4, "expected Rule for rule2")
	_, ok2p := rule2.production.(Ident)
	testing.expect(t, ok2p, "expected Ident for rule2 single production")
}

// A comment is also trivia inside a header, inside grouping symbols and inside
// the argument list of a call, where it must not be mistaken for an argument.
@(test)
test_parse_comments_in_header_groups_and_calls :: proc(t: ^testing.T) {
	src := `greet // who
  name // whom
  = <hello name // greeting
      "Mr">;
grouped = ( a // one
            b ) [ c ] { d };
`
	file := must_parse(t, src)
	defer destroy_file(&file)

	rule, ok := file.decls[0].(Rule)
	testing.expect(t, ok, "expected Rule")
	testing.expect(t, len(rule.params) == 1, "a comment must not be taken for a parameter")
	testing.expect(t, rule.params[0].name == "name", "wrong parameter")

	call_production, ok3 := rule.production.(^Call)
	testing.expect(t, ok3, "expected Call")
	testing.expect(t, len(call_production.args) == 2, "a comment must not be counted as an argument")

	other, ok5 := file.decls[1].(Rule)
	testing.expect(t, ok5, "expected Rule for grouped")
	seq2, ok7 := other.production.(Sequence)
	testing.expect(t, ok7, "expected Sequence for grouped")
	testing.expect(t, len(seq2.productions) == 3, "a comment must not add a sequence element")
	group, ok8 := seq2.productions[0].(Group)
	testing.expect(t, ok8, "expected Group")
	group_seq, ok9 := group.production^.(Sequence)
	testing.expect(t, ok9, "the group holds a sequence")
	testing.expect(t, len(group_seq.productions) == 2, "a comment must not add a group element")
}

@(test)
test_parse_group_repetition_optional :: proc(t: ^testing.T) {
	file := must_parse(t, `x = ( "a" { "b" "c" } [ "d" "e" ] );`)
	defer destroy_file(&file)

	rule, _ := file.decls[0].(Rule)
	group, ok := rule.production.(Group)
	testing.expect(t, ok, "expected Group")
	// A group holds one production, and `a { b c } [ d e ]` is a sequence of three.
	group_seq, ok2 := group.production^.(Sequence)
	testing.expect(t, ok2, "the group holds a sequence")
	testing.expect(t, len(group_seq.productions) == 3, "expected three elements in group")

	lit, ok3 := group_seq.productions[0].(String_Lit)
	testing.expect(t, ok3, "first element should be String_Lit")
	testing.expect(t, lit.value == `"a"`, "wrong first element")

	rep, ok4 := group_seq.productions[1].(Repetition)
	testing.expect(t, ok4, "second element should be Repetition")
	rep_seq, ok5 := rep.production^.(Sequence)
	testing.expect(t, ok5, "the repetition holds a sequence")
	testing.expect(t, len(rep_seq.productions) == 2, "repetition should hold two productions")
	lit2, ok6 := rep_seq.productions[0].(String_Lit)
	testing.expect(t, ok6, "repetition element should be String_Lit")
	testing.expect(t, lit2.value == `"b"`, "wrong repetition element")

	opt, ok7 := group_seq.productions[2].(Optional)
	testing.expect(t, ok7, "third element should be Optional")
	opt_seq, ok8 := opt.production^.(Sequence)
	testing.expect(t, ok8, "the optional holds a sequence")
	testing.expect(t, len(opt_seq.productions) == 2, "optional should hold two productions")
	lit3, ok9 := opt_seq.productions[0].(String_Lit)
	testing.expect(t, ok9, "optional element should be String_Lit")
	testing.expect(t, lit3.value == `"d"`, "wrong optional element")
}

@(test)
test_parse_external_value :: proc(t: ^testing.T) {
	// An external has a "__" prefix and no closing delimiter, so the name is
	// everything after the prefix.
	file := must_parse(t, `e = __name;`)
	defer destroy_file(&file)

	rule, _ := file.decls[0].(Rule)
	ext, ok := rule.production.(External_Value)
	testing.expect(t, ok, "expected External_Value")
	testing.expect(t, ext.name == "name", "external name should drop the leading __")
}

@(test)
test_parse_external_value_removes_trailing_delimiter :: proc(t: ^testing.T) {
	file := must_parse(t, `e = __name__;`)
	defer destroy_file(&file)

	rule, _ := file.decls[0].(Rule)
	ext, ok := rule.production.(External_Value)
	testing.expect(t, ok, "expected External_Value")
	testing.expect(t, ext.name == "name", "a trailing __ is not part of the name")
}

@(test)
test_parse_rule_without_body :: proc(t: ^testing.T) {
	tokens, _ := token.scan(`foo = ;`)
	defer delete(tokens)

	file, errors := parse_file(`foo = ;`, tokens[:])
	defer destroy_file(&file)
	defer delete(errors)
	testing.expect(t, len(errors) >= 1, "expected an error for a rule without a body")
	testing.expect(t, strings.contains(errors[0].message, "body"), "rule body error message")
}

@(test)
test_parse_missing_semicolon :: proc(t: ^testing.T) {
	tokens, _ := token.scan(`foo = "a"`)
	defer delete(tokens)

	file, errors := parse_file(`foo = "a"`, tokens[:])
	defer destroy_file(&file)
	defer delete(errors)
	testing.expect(t, len(errors) >= 1, "expected an error for a missing semicolon")
	testing.expect(
		t,
		strings.contains(errors[0].message, "Semicolon"),
		"missing semicolon error message",
	)
}

@(test)
test_parse_unclosed_group :: proc(t: ^testing.T) {
	tokens, _ := token.scan(`foo = ("a";`)
	defer delete(tokens)

	file, errors := parse_file(`foo = ("a";`, tokens[:])
	defer destroy_file(&file)
	defer delete(errors)
	testing.expect(t, len(errors) >= 1, "expected an error for an unclosed group")
}

@(test)
test_parse_unterminated_call :: proc(t: ^testing.T) {
	tokens, _ := token.scan(`foo = <bar;`)
	defer delete(tokens)

	file, errors := parse_file(`foo = <bar;`, tokens[:])
	defer destroy_file(&file)
	defer delete(errors)
	testing.expect(t, len(errors) >= 1, "expected an error for an unterminated call")
}

@(test)
test_parse_tag_on_a_single_element :: proc(t: ^testing.T) {
	file := must_parse(t, "foo = x `name=\"john\"`;")
	defer destroy_file(&file)

	tagged := must_tagged(t, file, "foo")
	ident, ok := tagged.production^.(Ident)
	testing.expect(t, ok, "the annotated production should be an Ident")
	testing.expect(t, ident.name == "x", "wrong tagged name")

	testing.expect(t, len(tagged.tag) == 1, "expected one pair")
	testing.expect(t, tagged.tag[0].ident.name == "name", "wrong pair name")
	testing.expect(t, tagged.tag[0].value.value == `"john"`, "wrong pair value")
}

// A tag annotates the whole sequence, not just the element it follows.
@(test)
test_parse_tag_wraps_the_whole_sequence :: proc(t: ^testing.T) {
	file := must_parse(t, "foo = x y `name=\"john\"`;")
	defer destroy_file(&file)

	tagged := must_tagged(t, file, "foo")
	seq, ok := tagged.production^.(Sequence)
	testing.expect(t, ok, "the annotated production should be the sequence")
	testing.expect(t, len(seq.productions) == 2, "a tag must not add an element")

	first, ok2 := seq.productions[0].(Ident)
	testing.expect(t, ok2, "the first element should be an Ident")
	testing.expect(t, first.name == "x", "wrong first element")

	second, ok3 := seq.productions[1].(Ident)
	testing.expect(t, ok3, "the last element should be an Ident")
	testing.expect(t, second.name == "y", "wrong last element")

	testing.expect(t, len(tagged.tag) == 1, "expected one pair")
	testing.expect(t, tagged.tag[0].ident.name == "name", "wrong pair name")
	// The wrapper reports where the annotated production starts, not where the
	// tag is written.
	testing.expect(t, tagged.pos == production_pos(seq), "the tag should report the production position")
}

@(test)
test_parse_tag_wraps_a_three_element_sequence :: proc(t: ^testing.T) {
	file := must_parse(t, "foo = a b c `name=\"value\"`;")
	defer destroy_file(&file)

	tagged := must_tagged(t, file, "foo")
	seq, ok := tagged.production^.(Sequence)
	testing.expect(t, ok, "the annotated production should be the sequence")
	want := []string{"a", "b", "c"}
	testing.expect(t, len(seq.productions) == len(want), "expected three elements")

	for production, i in seq.productions[:] {
		ident, is_ident := production.(Ident)
		testing.expect(t, is_ident, "every element should be an Ident")
		testing.expect(t, ident.name == want[i], "wrong element name")
	}
}

// A tag annotates a production, so each alternative is annotated on its own.
@(test)
test_parse_tag_wraps_each_alternative_sequence :: proc(t: ^testing.T) {
	file := must_parse(t, "foo = a b `first=\"1\"` | c d `second=\"2\"`;")
	defer destroy_file(&file)

	rule := must_rule(t, file, "foo")
	alts, ok := must_production(t, rule).(Alternative)
	testing.expect(t, ok, "expected Alternative")
	branches := collect_branches(alts)
	defer delete(branches)
	testing.expect(t, len(branches) == 2, "expected two alternatives")

	first, ok2 := branches[0].(Tagged_Production)
	testing.expect(t, ok2, "the first alternative should be tagged")
	first_seq, ok3 := first.production^.(Sequence)
	testing.expect(t, ok3, "the first alternative should be a sequence")
	testing.expect(t, len(first_seq.productions) == 2, "the first alternative has two elements")
	testing.expect(t, first.tag[0].ident.name == "first", "wrong first tag")

	second, ok4 := branches[1].(Tagged_Production)
	testing.expect(t, ok4, "the second alternative should be tagged")
	second_seq, ok5 := second.production^.(Sequence)
	testing.expect(t, ok5, "the second alternative should be a sequence")
	testing.expect(t, len(second_seq.productions) == 2, "the second alternative has two elements")
	testing.expect(t, second.tag[0].ident.name == "second", "wrong second tag")
}

// A production is annotated once, so a second tag has nothing left to annotate.
// Several pairs in one tag is the way to say more than one thing about it.
@(test)
test_parse_two_tags_rejected :: proc(t: ^testing.T) {
	expect_parse_error(
		t,
		"foo = a b `name=\"a\"` `age=\"100\"`;",
		"a production may carry only one tag",
	)
	expect_parse_error(
		t,
		"foo = a `name=\"a\"``age=\"100\"`;",
		"a production may carry only one tag",
	)
	// One tag per alternative is one tag each, so this stands.
	alt := must_parse(t, "alt = a `n=\"1\"` | b `n=\"2\"`;")
	defer destroy_file(&alt)
}

@(test)
test_parse_tag_with_several_pairs :: proc(t: ^testing.T) {
	file := must_parse(t, "foo = x `name=\"a\"; other=\"100\"`;")
	defer destroy_file(&file)

	tagged := must_tagged(t, file, "foo")
	testing.expect(t, len(tagged.tag) == 2, "expected two pairs")
	testing.expect(t, tagged.tag[0].ident.name == "name", "wrong first pair name")
	testing.expect(t, tagged.tag[0].value.value == `"a"`, "wrong first pair value")
	testing.expect(t, tagged.tag[1].ident.name == "other", "wrong second pair name")
	testing.expect(t, tagged.tag[1].value.value == `"100"`, "wrong second pair value")
	// Each pair keeps its own offset so a diagnostic can point at it.
	testing.expect(t, tagged.tag[0].pos < tagged.tag[1].pos, "pairs should be ordered by position")
}

@(test)
test_parse_tag_on_each_alternative :: proc(t: ^testing.T) {
	file := must_parse(t, "foo = x `a=\"1\"` | y `b=\"2\"`;")
	defer destroy_file(&file)

	rule := must_rule(t, file, "foo")
	alts, ok := must_production(t, rule).(Alternative)
	testing.expect(t, ok, "expected Alternative")
	branches := collect_branches(alts)
	defer delete(branches)
	testing.expect(t, len(branches) == 2, "expected two alternatives")

	first, ok2 := branches[0].(Tagged_Production)
	testing.expect(t, ok2, "the first alternative should be tagged")
	testing.expect(t, first.tag[0].ident.name == "a", "wrong first tag")

	second, ok3 := branches[1].(Tagged_Production)
	testing.expect(t, ok3, "the second alternative should be tagged")
	testing.expect(t, second.tag[0].ident.name == "b", "wrong second tag")
}

// A tag annotates a whole production, so it is written outside the group,
// repetition or optional that holds it.
@(test)
test_parse_tag_outside_a_group :: proc(t: ^testing.T) {
	file := must_parse(t, "foo = (x) `name=\"a\"`;")
	defer destroy_file(&file)

	tagged := must_tagged(t, file, "foo")
	group, ok := tagged.production^.(Group)
	testing.expect(t, ok, "the tagged element should be the group")
	// `(x)` holds the single production x, so the group is not a sequence.
	_, is_sequence := group.production^.(Sequence)
	testing.expect(t, !is_sequence, "a group of one production holds it directly")
}

@(test)
test_parse_tag_rejected_alone :: proc(t: ^testing.T) {
	expect_parse_error(t, "foo = `name=\"a\"`;", "a tag must annotate a production element")
}

@(test)
test_parse_tag_must_be_last :: proc(t: ^testing.T) {
	expect_parse_error(t, "foo = x `name=\"a\"` y;", "a tag must be the last element")
}

// A tag inside one of these annotates an element that is not the last of its
// production, so the enclosing production would have to end twice over.
@(test)
test_parse_tag_rejected_inside_a_group :: proc(t: ^testing.T) {
	expect_parse_error(t, "foo = (x `name=\"a\"`);", "may not appear inside")
}

@(test)
test_parse_tag_rejected_inside_a_repetition :: proc(t: ^testing.T) {
	expect_parse_error(t, "foo = {x `name=\"a\"`};", "may not appear inside")
}

@(test)
test_parse_tag_rejected_inside_an_optional :: proc(t: ^testing.T) {
	expect_parse_error(t, "foo = [x `name=\"a\"`];", "may not appear inside")
}

@(test)
test_parse_tag_rejected_inside_a_call :: proc(t: ^testing.T) {
	expect_parse_error(t, "foo = <bar x `name=\"a\"`>;", "may not appear inside")
}

// The tokenizer reports a malformed tag, and the parser then builds no pairs out
// of text it did not understand: one diagnostic for one problem.
@(test)
test_parse_malformed_tag :: proc(t: ^testing.T) {
	src := "foo = x `name=`;"
	tokens, token_errors := token.scan(src)
	defer delete(tokens)
	defer delete(token_errors)
	// The scanner reports the malformed tag and still hands the parser a token.
	testing.expect(t, len(token_errors) == 1, "expected one token error")

	file, errors := parse_file(src, tokens[:])
	defer destroy_file(&file)
	defer delete(errors)
	testing.expect(t, len(errors) == 0, "the parser should not repeat the scanner's error")

	tagged := must_tagged(t, file, "foo")
	testing.expect(t, len(tagged.tag) == 0, "a malformed tag yields no pairs")
}

// must_production returns the single production of a rule.
must_production :: proc(t: ^testing.T, rule: Rule) -> Production {
	return rule.production
}

// must_tagged parses a one rule source and returns the single Tagged_Production of its
// production.
must_tagged :: proc(t: ^testing.T, file: File, name: string) -> Tagged_Production {
	rule := must_rule(t, file, name)
	tagged, ok := must_production(t, rule).(Tagged_Production)
	testing.expectf(t, ok, "the production of %s should be a Tagged_Production", name)
	return tagged
}

// must_rule returns the named rule declaration of file.
must_rule :: proc(t: ^testing.T, file: File, name: string) -> Rule {
	for decl in file.decls {
		if rule, ok := decl.(Rule); ok && rule.ident.name == name {
			return rule
		}
	}
	testing.expectf(t, false, "no rule named %s", name)
	return {}
}

// expect_parse_error asserts that src fails to parse with a message containing
// want.
expect_parse_error :: proc(t: ^testing.T, src, want: string) {
	tokens, _ := token.scan(src)
	defer delete(tokens)

	file, errors := parse_file(src, tokens[:])
	defer destroy_file(&file)
	defer delete(errors)

	testing.expectf(t, len(errors) >= 1, "expected an error for %q", src)
	testing.expectf(
		t,
		strings.contains(error_summary(errors[:]), want),
		"expected %q to mention %q",
		src,
		want,
	)
}

@(test)
test_parse_example_files :: proc(t: ^testing.T) {
	files := collect_example_grammars()
	defer delete_files(files)

	for file in files {
		data, err := os.read_entire_file_from_path(file, context.allocator)
		if err != nil {
			testing.expectf(t, false, "could not read %s", file)
			continue
		}
		defer delete(data)
		src := string(data)

		tokens, token_errors := token.scan(src)
		defer delete(tokens)
		defer delete(token_errors)

		parsed, parse_errors := parse_file(src, tokens[:])
		defer destroy_file(&parsed)
		defer delete(parse_errors)

		if len(parse_errors) > 0 {
			msg := fmt.tprintf(
				"%s: expected clean parse, got %s",
				file,
				error_summary(parse_errors[:]),
			)
			testing.expectf(t, false, "%s", msg)
		}
	}
}

// must_parse parses src and fails the test on any parse or token error.
must_parse :: proc(t: ^testing.T, src: string) -> File {
	tokens, token_errors := token.scan(src)
	defer delete(tokens)
	defer delete(token_errors)
	testing.expectf(t, len(token_errors) == 0, "unexpected token errors for %q", src)

	file, errors := parse_file(src, tokens[:])
	defer delete(errors)
	testing.expectf(
		t,
		len(errors) == 0,
		"unexpected parse errors for %q: %s",
		src,
		error_summary(errors[:]),
	)
	return file
}

error_summary :: proc(errors: []Error) -> string {
	if len(errors) == 0 do return ""
	return fmt.tprintf("(%d errors, first: %s)", len(errors), errors[0].message)
}

collect_example_grammars :: proc() -> [dynamic]string {
	w := os.walker_create("../example")
	defer os.walker_destroy(&w)

	files := make([dynamic]string)
	for info in os.walker_walk(&w) {
		if info.type == .Regular && strings.has_suffix(info.fullpath, ".grammar") {
			append(&files, strings.clone(info.fullpath))
		}
	}
	return files
}

delete_files :: proc(files: [dynamic]string) {
	for f in files do delete(f)
	delete(files)
}
