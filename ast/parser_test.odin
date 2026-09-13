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
	file := must_parse(t, `e = __name__;`)
	defer destroy_file(&file)

	rule, _ := file.decls[0].(Rule_Decl)
	term, _ := rule.body[0].(Term_Expr)
	ext, ok := term.x.(External_Value)
	testing.expect(t, ok, "expected External_Value")
	testing.expect(t, ext.name == "name", "external name should be stripped of underscores")
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
