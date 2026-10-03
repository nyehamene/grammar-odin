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

	rule, ok := file.decls[0].(Rule_Decl)
	testing.expect(t, ok, "expected Rule_Decl")
	testing.expect(t, rule.name.name == "greeting", "wrong rule name")
	testing.expect(t, len(rule.params) == 0, "no parameters expected")

	term, ok2 := rule.body[0].(Term_Expr)
	testing.expect(t, ok2, "expected Term_Expr in rule body")
	alts, ok3 := term.x.(Alternative_Expr)
	testing.expect(t, ok3, "expected Alternative_Expr inside Term_Expr")
	testing.expect(t, len(alts.exprs) == 2, "expected two alternatives")

	s1, ok4 := alts.exprs[0].(String_Lit)
	testing.expect(t, ok4, "first alt should be String_Lit")
	testing.expect(t, s1.value == `"Hello"`, "wrong value for first alt")
	s2, ok5 := alts.exprs[1].(String_Lit)
	testing.expect(t, ok5, "second alt should be String_Lit")
	testing.expect(t, s2.value == `"Hi"`, "wrong value for second alt")
}

@(test)
test_parse_sequence :: proc(t: ^testing.T) {
	file := must_parse(t, `rule = greeting " World";`)
	defer destroy_file(&file)

	rule, _ := file.decls[0].(Rule_Decl)
	term, _ := rule.body[0].(Term_Expr)
	seq, ok := term.x.(Sequence_Expr)
	testing.expect(t, ok, "expected Sequence_Expr")
	testing.expect(t, len(seq.exprs) == 2, "expected two elements")

	ident, ok2 := seq.exprs[0].(Ident)
	testing.expect(t, ok2, "first element should be Ident")
	testing.expect(t, ident.name == "greeting", "wrong ident name")
}

@(test)
test_parse_binding :: proc(t: ^testing.T) {
	file := must_parse(t, `f = @import("../foo");`)
	defer destroy_file(&file)

	binding, ok := file.decls[0].(Binding_Decl)
	testing.expect(t, ok, "expected Binding_Decl")
	testing.expect(t, binding.name.name == "f", "wrong binding name")
	testing.expect(t, binding.path.value == `"../foo"`, "wrong import path")
}

@(test)
test_parse_rule_with_params :: proc(t: ^testing.T) {
	file := must_parse(t, `greet name title = "hello" name title;`)
	defer destroy_file(&file)

	rule, _ := file.decls[0].(Rule_Decl)
	testing.expect(t, len(rule.params) == 2, "expected two parameters")
	testing.expect(t, rule.params[0].name == "name", "wrong first param")
	testing.expect(t, rule.params[1].name == "title", "wrong second param")
}

@(test)
test_parse_call :: proc(t: ^testing.T) {
	file := must_parse(t, `fancy = <greet person "Mr">;`)
	defer destroy_file(&file)

	rule, _ := file.decls[0].(Rule_Decl)
	term, _ := rule.body[0].(Term_Expr)
	call, ok := term.x.(^Call_Expr)
	testing.expect(t, ok, "expected Call_Expr")

	ident, i_ok := call.name.(Ident)
	testing.expect(t, ok, "expected Call_Expr name bet ident")

	testing.expect(t, ident.name == "greet", "wrong callee")
	testing.expect(t, len(call.args) == 2, "expected two arguments")

	arg0, _ := call.args[0].(Ident)
	testing.expect(t, arg0.name == "person", "wrong first argument")
	arg1, _ := call.args[1].(String_Lit)
	testing.expect(t, arg1.value == `"Mr"`, "wrong second argument")
}

@(test)
test_parse_member_access :: proc(t: ^testing.T) {
	file := must_parse(t, `m = foo.bar.baz;`)
	defer destroy_file(&file)

	rule, _ := file.decls[0].(Rule_Decl)
	term, _ := rule.body[0].(Term_Expr)
	member, ok := term.x.(Member_Expr)
	testing.expect(t, ok, "expected Member_Expr")
	testing.expect(t, member.member.name == "baz", "outer member should be baz")

	inner, _ := member.object.(Member_Expr)
	testing.expect(t, inner.member.name == "bar", "inner member should be bar")
}

@(test)
test_parse_comments :: proc(t: ^testing.T) {
	file := must_parse(t, "// hi\nrule = \"a\";\n")
	defer destroy_file(&file)

	comments, ok := file.decls[0].(Comment_Group)
	testing.expect(t, ok, "expected Comment_Group first")
	testing.expect(t, strings.contains(comments.list[0].text, "hi"), "comment text preserved")
	_, ok = file.decls[1].(Rule_Decl)
	testing.expect(t, ok, "expected Rule_Decl after comment")
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

	rule1, ok := file.decls[0].(Rule_Decl)
	testing.expect(t, ok, "expected Rule_Decl for rule1")
	testing.expect(t, rule1.name.name == "rule1", "wrong rule1 name")
	testing.expect(t, len(rule1.body) == 1, "a comment must not add a body element")

	// Both alternatives survive the trailing comments.
	term, ok2 := rule1.body[0].(Term_Expr)
	testing.expect(t, ok2, "expected Term_Expr for rule1 body")
	alt, ok3 := term.x.(Alternative_Expr)
	testing.expect(t, ok3, "expected Alternative_Expr for rule1")
	testing.expect(t, len(alt.exprs) == 2, "expected two alternatives")

	rule2, ok4 := file.decls[1].(Rule_Decl)
	testing.expect(t, ok4, "expected Rule_Decl for rule2")
	testing.expect(t, len(rule2.body) == 1, "expected one body element for rule2")
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

	rule, ok := file.decls[0].(Rule_Decl)
	testing.expect(t, ok, "expected Rule_Decl")
	testing.expect(t, len(rule.params) == 1, "a comment must not be taken for a parameter")
	testing.expect(t, rule.params[0].name == "name", "wrong parameter")

	call, ok2 := rule.body[0].(Term_Expr)
	testing.expect(t, ok2, "expected Term_Expr")
	call_expr, ok3 := call.x.(^Call_Expr)
	testing.expect(t, ok3, "expected Call_Expr")
	testing.expect(t, len(call_expr.args) == 2, "a comment must not be counted as an argument")

	other, ok5 := file.decls[1].(Rule_Decl)
	testing.expect(t, ok5, "expected Rule_Decl for grouped")
	term2, ok6 := other.body[0].(Term_Expr)
	testing.expect(t, ok6, "expected Term_Expr for grouped")
	seq2, ok7 := term2.x.(Sequence_Expr)
	testing.expect(t, ok7, "expected Sequence_Expr for grouped")
	testing.expect(t, len(seq2.exprs) == 3, "a comment must not add a sequence element")
	group, ok8 := seq2.exprs[0].(Group_Expr)
	testing.expect(t, ok8, "expected Group_Expr")
	testing.expect(t, len(group.exprs) == 2, "a comment must not add a group element")
}

@(test)
test_parse_group_repetition_optional :: proc(t: ^testing.T) {
	file := must_parse(t, `x = ( "a" { "b" "c" } [ "d" "e" ] );`)
	defer destroy_file(&file)

	rule, _ := file.decls[0].(Rule_Decl)
	term, _ := rule.body[0].(Term_Expr)
	group, ok := term.x.(Group_Expr)
	testing.expect(t, ok, "expected Group_Expr")
	testing.expect(t, len(group.exprs) == 3, "expected three elements in group")

	lit, ok2 := group.exprs[0].(String_Lit)
	testing.expect(t, ok2, "first element should be String_Lit")
	testing.expect(t, lit.value == `"a"`, "wrong first element")

	rep, ok3 := group.exprs[1].(Repetition_Expr)
	testing.expect(t, ok3, "second element should be Repetition_Expr")
	testing.expect(t, len(rep.exprs) == 2, "repetition should hold two expressions")
	lit2, ok4 := rep.exprs[0].(String_Lit)
	testing.expect(t, ok4, "repetition element should be String_Lit")
	testing.expect(t, lit2.value == `"b"`, "wrong repetition element")

	opt, ok5 := group.exprs[2].(Optional_Expr)
	testing.expect(t, ok5, "third element should be Optional_Expr")
	testing.expect(t, len(opt.exprs) == 2, "optional should hold two expressions")
	lit3, ok6 := opt.exprs[0].(String_Lit)
	testing.expect(t, ok6, "optional element should be String_Lit")
	testing.expect(t, lit3.value == `"d"`, "wrong optional element")
}

@(test)
test_parse_external_value :: proc(t: ^testing.T) {
	// An external has a "__" prefix and no closing delimiter, so the name is
	// everything after the prefix.
	file := must_parse(t, `e = __name;`)
	defer destroy_file(&file)

	rule, _ := file.decls[0].(Rule_Decl)
	term, _ := rule.body[0].(Term_Expr)
	ext, ok := term.x.(External_Value)
	testing.expect(t, ok, "expected External_Value")
	testing.expect(t, ext.name == "name", "external name should drop the leading __")
}

@(test)
test_parse_external_value_removes_trailing_delimiter :: proc(t: ^testing.T) {
	file := must_parse(t, `e = __name__;`)
	defer destroy_file(&file)

	rule, _ := file.decls[0].(Rule_Decl)
	term, _ := rule.body[0].(Term_Expr)
	ext, ok := term.x.(External_Value)
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
	ident, ok := tagged.expr^.(Ident)
	testing.expect(t, ok, "the annotated production should be an Ident")
	testing.expect(t, ident.name == "x", "wrong tagged name")

	testing.expect(t, len(tagged.tag) == 1, "expected one pair")
	testing.expect(t, tagged.tag[0].name.name == "name", "wrong pair name")
	testing.expect(t, tagged.tag[0].value.value == `"john"`, "wrong pair value")
}

// A tag annotates the whole sequence, not just the element it follows.
@(test)
test_parse_tag_wraps_the_whole_sequence :: proc(t: ^testing.T) {
	file := must_parse(t, "foo = x y `name=\"john\"`;")
	defer destroy_file(&file)

	tagged := must_tagged(t, file, "foo")
	seq, ok := tagged.expr^.(Sequence_Expr)
	testing.expect(t, ok, "the annotated production should be the sequence")
	testing.expect(t, len(seq.exprs) == 2, "a tag must not add an element")

	first, ok2 := seq.exprs[0].(Ident)
	testing.expect(t, ok2, "the first element should be an Ident")
	testing.expect(t, first.name == "x", "wrong first element")

	second, ok3 := seq.exprs[1].(Ident)
	testing.expect(t, ok3, "the last element should be an Ident")
	testing.expect(t, second.name == "y", "wrong last element")

	testing.expect(t, len(tagged.tag) == 1, "expected one pair")
	testing.expect(t, tagged.tag[0].name.name == "name", "wrong pair name")
	// The wrapper reports where the annotated production starts, not where the
	// tag is written.
	testing.expect(t, tagged.pos == expr_pos(seq), "the tag should report the production position")
}

@(test)
test_parse_tag_wraps_a_three_element_sequence :: proc(t: ^testing.T) {
	file := must_parse(t, "foo = a b c `name=\"value\"`;")
	defer destroy_file(&file)

	tagged := must_tagged(t, file, "foo")
	seq, ok := tagged.expr^.(Sequence_Expr)
	testing.expect(t, ok, "the annotated production should be the sequence")
	want := []string{"a", "b", "c"}
	testing.expect(t, len(seq.exprs) == len(want), "expected three elements")

	for expr, i in seq.exprs[:] {
		ident, is_ident := expr.(Ident)
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
	alts, ok := must_production(t, rule).(Alternative_Expr)
	testing.expect(t, ok, "expected Alternative_Expr")
	testing.expect(t, len(alts.exprs) == 2, "expected two alternatives")

	first, ok2 := alts.exprs[0].(Tagged_Expr)
	testing.expect(t, ok2, "the first alternative should be tagged")
	first_seq, ok3 := first.expr^.(Sequence_Expr)
	testing.expect(t, ok3, "the first alternative should be a sequence")
	testing.expect(t, len(first_seq.exprs) == 2, "the first alternative has two elements")
	testing.expect(t, first.tag[0].name.name == "first", "wrong first tag")

	second, ok4 := alts.exprs[1].(Tagged_Expr)
	testing.expect(t, ok4, "the second alternative should be tagged")
	second_seq, ok5 := second.expr^.(Sequence_Expr)
	testing.expect(t, ok5, "the second alternative should be a sequence")
	testing.expect(t, len(second_seq.exprs) == 2, "the second alternative has two elements")
	testing.expect(t, second.tag[0].name.name == "second", "wrong second tag")
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
	testing.expect(t, tagged.tag[0].name.name == "name", "wrong first pair name")
	testing.expect(t, tagged.tag[0].value.value == `"a"`, "wrong first pair value")
	testing.expect(t, tagged.tag[1].name.name == "other", "wrong second pair name")
	testing.expect(t, tagged.tag[1].value.value == `"100"`, "wrong second pair value")
	// Each pair keeps its own offset so a diagnostic can point at it.
	testing.expect(
		t,
		tagged.tag[0].pos < tagged.tag[1].pos,
		"pairs should be ordered by position",
	)
}

@(test)
test_parse_tag_on_each_alternative :: proc(t: ^testing.T) {
	file := must_parse(t, "foo = x `a=\"1\"` | y `b=\"2\"`;")
	defer destroy_file(&file)

	rule := must_rule(t, file, "foo")
	alts, ok := must_production(t, rule).(Alternative_Expr)
	testing.expect(t, ok, "expected Alternative_Expr")
	testing.expect(t, len(alts.exprs) == 2, "expected two alternatives")

	first, ok2 := alts.exprs[0].(Tagged_Expr)
	testing.expect(t, ok2, "the first alternative should be tagged")
	testing.expect(t, first.tag[0].name.name == "a", "wrong first tag")

	second, ok3 := alts.exprs[1].(Tagged_Expr)
	testing.expect(t, ok3, "the second alternative should be tagged")
	testing.expect(t, second.tag[0].name.name == "b", "wrong second tag")
}

// A tag annotates a whole production, so it is written outside the group,
// repetition or optional that holds it.
@(test)
test_parse_tag_outside_a_group :: proc(t: ^testing.T) {
	file := must_parse(t, "foo = (x) `name=\"a\"`;")
	defer destroy_file(&file)

	tagged := must_tagged(t, file, "foo")
	group, ok := tagged.expr^.(Group_Expr)
	testing.expect(t, ok, "the tagged element should be the group")
	testing.expect(t, len(group.exprs) == 1, "expected one element in the group")
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

// must_production returns the single production of a rule, looking through the
// Term_Expr that wraps it.
must_production :: proc(t: ^testing.T, rule: Rule_Decl) -> Expr {
	testing.expectf(t, len(rule.body) == 1, "%s should have one production", rule.name.name)
	term, ok := rule.body[0].(Term_Expr)
	testing.expectf(t, ok, "the production of %s should be wrapped in a Term_Expr", rule.name.name)
	return term.x^
}

// must_tagged parses a one rule source and returns the single Tagged_Expr of its
// production.
must_tagged :: proc(t: ^testing.T, file: File, name: string) -> Tagged_Expr {
	rule := must_rule(t, file, name)
	tagged, ok := must_production(t, rule).(Tagged_Expr)
	testing.expectf(t, ok, "the production of %s should be a Tagged_Expr", name)
	return tagged
}

// must_rule returns the named rule declaration of file.
must_rule :: proc(t: ^testing.T, file: File, name: string) -> Rule_Decl {
	for decl in file.decls {
		if rule, ok := decl.(Rule_Decl); ok && rule.name.name == name {
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
