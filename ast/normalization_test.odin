package ast

import "core:strings"
import "core:testing"

// scope_of returns a scope holding every rule in file. The scope shares the rules
// the file holds, so the file has to outlive it. The caller owns the scope and
// frees it with delete(scope.rules_by_name).
scope_of :: proc(file: ^File) -> Scope {
	scope: Scope
	for decl in file.decls {
		rule := decl.(Rule) or_continue
		scope.rules_by_name[rule.ident.name] = rule
	}
	return scope
}

// expand_one parses source, expands the rule named name against every rule source
// declares, and returns the expanded rule, whether every call in it was expanded,
// and the scope it was expanded against. source has to parse cleanly.
//
// The caller owns all three: the rule with destroy_rule, the scope with
// delete(scope.rules_by_name).
expand_one :: proc(t: ^testing.T, source, name: string) -> (Rule, bool, Scope) {
	file := must_parse(t, source)
	defer destroy_file(&file)

	scope := scope_of(&file)
	expanded, ok := expand_rule(scope.rules_by_name[name], &scope)
	return expanded, ok, scope
}

// shape renders p as a compact s-expression, leaving positions out, so that an
// assertion reads as the tree it describes. The caller owns the result.
shape :: proc(p: Production) -> string {
	b := strings.builder_make(context.temp_allocator)
	shape_into(&b, p)
	return strings.clone(strings.to_string(b))
}

shape_into :: proc(b: ^strings.Builder, p: Production) {
	switch it in p {
	case Ident:
		strings.write_string(b, it.name)
	case String_Lit:
		strings.write_string(b, it.value)
	case Regex_Lit:
		strings.write_string(b, it.value)
	case External_Value:
		strings.write_string(b, "__")
		strings.write_string(b, it.name)
		strings.write_string(b, "__")
	case Qual_Ident:
		strings.write_string(b, it.lhs.name)
		strings.write_rune(b, '.')
		strings.write_string(b, it.rhs.name)
	case Sequence:
		shape_group(b, "seq", it.exprs[:])
	case Alternative:
		shape_group(b, "alt", it.exprs[:])
	case Optional:
		shape_group(b, "opt", it.exprs[:])
	case Repetition:
		shape_group(b, "rep", it.exprs[:])
	case Group:
		shape_group(b, "grp", it.exprs[:])
	case Tagged_Production:
		strings.write_string(b, "tag(")
		shape_into(b, it.expr^)
		strings.write_rune(b, ')')
	case Directive:
		strings.write_rune(b, '@')
		strings.write_string(b, it.ident.name)
	case ^Call:
		strings.write_string(b, "call(")
		shape_name_into(b, it.ident)
		for arg in it.args {
			strings.write_rune(b, ',')
			strings.write_rune(b, ' ')
			shape_into(b, arg)
		}
		strings.write_rune(b, ')')
	}
}

shape_group :: proc(b: ^strings.Builder, label: string, prods: []Production) {
	strings.write_string(b, label)
	strings.write_rune(b, '(')
	for prod, i in prods {
		if i > 0 do strings.write_rune(b, ' ')
		shape_into(b, prod)
	}
	strings.write_rune(b, ')')
}

shape_name_into :: proc(b: ^strings.Builder, name: Any_Ident) {
	switch it in name {
	case Ident:
		strings.write_string(b, it.name)
	case Qual_Ident:
		strings.write_string(b, it.lhs.name)
		strings.write_rune(b, '.')
		strings.write_string(b, it.rhs.name)
	}
}

// expect_shape checks that p renders as want, and reports what it rendered as.
expect_shape :: proc(t: ^testing.T, p: Production, want: string) {
	got := shape(p)
	defer delete(got)
	testing.expectf(t, got == want, "got %s, want %s", got, want)
}

// A call in the middle of a body is expanded along with the ones around it, and a
// callee body that came out as a sequence is spliced into the body that called it
// rather than nested inside it.
@(test)
test_expand_rule_inlines_a_chain_of_calls :: proc(t: ^testing.T) {
	expanded, ok, scope := expand_one(
		t,
		`
		item x = x { x };
		wrap x y = <item x> y;
		call_site = <wrap "p" "q"> "z";
		`,
		"call_site",
	)
	defer destroy_rule(&expanded)
	defer delete(scope.rules_by_name)

	testing.expect(t, ok, "every call of call_site should expand")
	testing.expect(t, !has_call(expanded.expr), "an expanded rule holds no call")
	expect_shape(t, expanded.expr, `seq("p" rep("p") "q" "z")`)
}

// Two call sites of one rule, expanded against the same scope, substitute their own
// arguments: neither leaves the shared callee rewritten for the other.
@(test)
test_expand_rule_gives_each_call_its_own_arguments :: proc(t: ^testing.T) {
	file := must_parse(t, `
		item x = x { x };
		first = <item "a">;
		second = <item "b">;
		`)
	defer destroy_file(&file)

	scope := scope_of(&file)
	defer delete(scope.rules_by_name)

	first, ok_first := expand_rule(scope.rules_by_name["first"], &scope)
	defer destroy_rule(&first)
	testing.expect(t, ok_first, "every call of first should expand")
	expect_shape(t, first.expr, `seq("a" rep("a"))`)

	second, ok_second := expand_rule(scope.rules_by_name["second"], &scope)
	defer destroy_rule(&second)
	testing.expect(t, ok_second, "every call of second should expand")
	expect_shape(t, second.expr, `seq("b" rep("b"))`)
}

// Expanding one rule writes nothing back into the scope, so a rule reached through
// two call sites is still the rule the scope holds.
@(test)
test_expand_rule_leaves_the_scope_unchanged :: proc(t: ^testing.T) {
	first, _, scope := expand_one(
		t,
		`
		item x = x { x };
		wrap x = <item x>;
		first = <wrap "a">;
		`,
		"first",
	)
	defer destroy_rule(&first)
	defer delete(scope.rules_by_name)

	expect_shape(t, first.expr, `seq("a" rep("a"))`)
	expect_shape(t, scope.rules_by_name["item"].expr, `seq(x rep(x))`)
	expect_shape(t, scope.rules_by_name["wrap"].expr, `call(item, x)`)
}

// A call the scope cannot resolve is reported rather than dropped, and is left in
// the body so that the caller can say which call it was.
@(test)
test_expand_rule_reports_a_call_it_cannot_resolve :: proc(t: ^testing.T) {
	expanded, ok, scope := expand_one(t, `use = <nope "a">;`, "use")
	defer destroy_rule(&expanded)
	defer delete(scope.rules_by_name)

	testing.expect(t, !ok, "an undeclared callee cannot be expanded")
	expect_shape(t, expanded.expr, `call(nope, "a")`)
}

// A callee in another namespace is not in this scope, so it is reported the same
// way rather than resolved or fatal.
@(test)
test_expand_rule_reports_a_qualified_callee :: proc(t: ^testing.T) {
	expanded, ok, scope := expand_one(
		t,
		`
		Z = @import("z.grammar");
		use = <Z.Rule "a">;
		`,
		"use",
	)
	defer destroy_rule(&expanded)
	defer delete(scope.rules_by_name)

	testing.expect(t, !ok, "a callee of another namespace cannot be expanded")
	expect_shape(t, expanded.expr, `call(Z.Rule, "a")`)
}

// Rules that call each other never run out of calls, so the depth bound is what
// ends the expansion.
@(test)
test_expand_rule_stops_on_a_cycle :: proc(t: ^testing.T) {
	expanded, ok, scope := expand_one(t, `loop x = <loop x>;`, "loop")
	defer destroy_rule(&expanded)
	defer delete(scope.rules_by_name)

	testing.expect(t, !ok, "a cycle of calls cannot be expanded")
	testing.expect(t, has_call(expanded.expr), "the call is left in place")
}

// A parameter that reaches a callee is substituted as the receiver of a member
// access there, so a callee reached through a parameter stands in the right place.
@(test)
test_expand_rule_substitutes_a_parameter_in_a_receiver :: proc(t: ^testing.T) {
	expanded, ok, scope := expand_one(
		t,
		`
		wrap ns = <ns.Rule>;
		use ns = <wrap target>;
		`,
		"use",
	)
	defer destroy_rule(&expanded)
	defer delete(scope.rules_by_name)

	// `target` stands in for `ns`, so the call names another rule of another
	// namespace and is the one thing left in the body.
	testing.expect(t, !ok, "a callee of another namespace cannot be expanded")
	expect_shape(t, expanded.expr, `call(target.Rule)`)
}

// An alternative holds whole branches, so a callee body that came out as a
// sequence stays one branch rather than joining the alternatives beside it.
@(test)
test_expand_rule_keeps_a_sequence_inside_an_alternative :: proc(t: ^testing.T) {
	expanded, ok, scope := expand_one(
		t,
		`
		pair x y = x y;
		choice = <pair "a" "b"> | "c";
		`,
		"choice",
	)
	defer destroy_rule(&expanded)
	defer delete(scope.rules_by_name)

	testing.expect(t, ok, "every call of choice should expand")
	expect_shape(t, expanded.expr, `alt(seq("a" "b") "c")`)
}
