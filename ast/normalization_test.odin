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

// normalize_one parses source, factors the rule named name, and returns it with
// whether the expansion it rests on finished. source has to parse cleanly. opts
// belongs to the caller.
normalize_one :: proc(
	t: ^testing.T,
	source, name: string,
	opts: ^Normalize_Options,
) -> (Normalized_Rule, bool) {
	file := must_parse(t, source)
	defer destroy_file(&file)

	scope := scope_of(&file)
	defer delete(scope.rules_by_name)

	return normalize_rule(scope.rules_by_name[name], &scope, opts)
}

// shape_normalized renders a production of the normalized tree, and an absent one as
// nothing. The caller owns the result.
shape_normalized :: proc(n: Normalized_Production) -> string {
	b := strings.builder_make(context.temp_allocator)
	shape_normalized_into(&b, n)
	return strings.clone(strings.to_string(b))
}

shape_normalized_into :: proc(b: ^strings.Builder, n: Normalized_Production) {
	if n.kind == nil {
		strings.write_string(b, "nothing")
		return
	}
	switch it in n.kind {
	case Nothing:
		strings.write_string(b, "nothing")
	case Production:
		shape_into(b, it)
	case ^Factored:
		strings.write_string(b, "factor(")
		shape_normalized_into(b, it.leading)
		for part in it.body[:] {
			strings.write_string(b, " | ")
			shape_normalized_into(b, part)
		}
		strings.write_string(b, " ; ")
		shape_normalized_into(b, it.trailing)
		strings.write_rune(b, ')')
	case ^Grouped:
		switch it.shape {
		case .Sequence:
			shape_normalized_group(b, "seq", it.exprs[:])
		case .Group:
			shape_normalized_group(b, "grp", it.exprs[:])
		case .Optional:
			shape_normalized_group(b, "opt", it.exprs[:])
		case .Repetition:
			shape_normalized_group(b, "rep", it.exprs[:])
		case .Tagged:
			strings.write_string(b, "tag(")
			for pair, i in it.tag[:] {
				if i > 0 do strings.write_rune(b, ' ')
				strings.write_string(b, pair.ident.name)
				strings.write_rune(b, '=')
				strings.write_string(b, pair.value.value)
			}
			for expr in it.exprs[:] {
				strings.write_rune(b, ' ')
				shape_normalized_into(b, expr)
			}
			strings.write_rune(b, ')')
		}
	}
}

shape_normalized_group :: proc(
	b: ^strings.Builder,
	label: string,
	exprs: []Normalized_Production,
) {
	strings.write_string(b, label)
	strings.write_rune(b, '(')
	for expr, i in exprs {
		if i > 0 do strings.write_rune(b, ' ')
		shape_normalized_into(b, expr)
	}
	strings.write_rune(b, ')')
}

// branch_shapes_into writes the shape of each production the leading, a middle or the
// trailing contributes to a branch: the elements of a sequence, or the one production it
// is.
// A tag is left out, since a name for a production is not part of what a rule
// matches.
branch_shapes_into :: proc(b: ^strings.Builder, n: Normalized_Production) {
	if n.kind == nil do return
	switch it in n.kind {
	case Nothing:
	case Production:
		shape_into(b, it)
		strings.write_rune(b, ' ')
	case ^Factored:
		shape_normalized_into(b, n)
		strings.write_rune(b, ' ')
	case ^Grouped:
		if it.shape == .Sequence || it.shape == .Tagged {
			for expr in it.exprs[:] do branch_shapes_into(b, expr)
			break
		}
		shape_normalized_into(b, n)
		strings.write_rune(b, ' ')
	}
}

// shape_rule writes out every branch a normalized rule matches, the leading and the
// trailing put back around each middle, so that a fact about what the rule matches can
// be asserted without asserting about how it was factored. The caller owns the result.
shape_rule :: proc(n: ^Normalized_Rule) -> string {
	leading := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&leading)
	trailing := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&trailing)
	branches := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&branches)

	branch_shapes_into(&leading, n.leading)
	branch_shapes_into(&trailing, n.trailing)

	for middle, i in n.body[:] {
		if i > 0 do strings.write_string(&branches, "| ")
		strings.write_string(&branches, strings.to_string(leading))
		branch_shapes_into(&branches, middle)
		strings.write_string(&branches, strings.to_string(trailing))
	}
	return strings.clone(strings.trim_space(strings.to_string(branches)))
}

expect_shape_normalized :: proc(t: ^testing.T, n: Normalized_Production, want: string) {
	got := shape_normalized(n)
	defer delete(got)
	testing.expectf(t, got == want, "got %s, want %s", got, want)
}

expect_shape_rule :: proc(t: ^testing.T, n: ^Normalized_Rule, want: string) {
	got := shape_rule(n)
	defer delete(got)
	testing.expectf(t, got == want, "got %s, want %s", got, want)
}

expect_body_len :: proc(t: ^testing.T, n: ^Normalized_Rule, want: int) {
	testing.expectf(t, len(n.body) == want, "got %d branches, want %d", len(n.body), want)
}

// A rule body is split into what every branch shares at the start, what is left for
// each branch, and what every branch shares at the end.
@(test)
test_normalize_rule_factors_a_common_head_and_tail :: proc(t: ^testing.T) {
	opts := Normalize_Options{}
	defer destroy_normalize_options(&opts)

	normalized, ok := normalize_one(t, `use = p a q | p b q;`, "use", &opts)
	defer destroy_normalized_rule(&normalized)

	testing.expect(t, ok, "a body with no call expands to the end")
	expect_shape_normalized(t, normalized.leading, `p`)
	expect_body_len(t, &normalized, 2)
	expect_shape_normalized(t, normalized.body[0], `a`)
	expect_shape_normalized(t, normalized.body[1], `b`)
	expect_shape_normalized(t, normalized.trailing, `q`)
	expect_shape_rule(t, &normalized, `p a q | p b q`)
}

@(test)
test_normalize_rule_factors_a_head_only :: proc(t: ^testing.T) {
	opts := Normalize_Options{}
	defer destroy_normalize_options(&opts)

	normalized, _ := normalize_one(t, `use = x a | x b;`, "use", &opts)
	defer destroy_normalized_rule(&normalized)

	expect_shape_normalized(t, normalized.leading, `x`)
	expect_shape_normalized(t, normalized.body[0], `a`)
	expect_shape_normalized(t, normalized.body[1], `b`)
	expect_shape_normalized(t, normalized.trailing, `nothing`)
	expect_shape_rule(t, &normalized, `x a | x b`)
}

@(test)
test_normalize_rule_factors_a_tail_only :: proc(t: ^testing.T) {
	opts := Normalize_Options{}
	defer destroy_normalize_options(&opts)

	normalized, _ := normalize_one(t, `use = a x | b x;`, "use", &opts)
	defer destroy_normalized_rule(&normalized)

	expect_shape_normalized(t, normalized.leading, `nothing`)
	expect_shape_normalized(t, normalized.body[0], `a`)
	expect_shape_normalized(t, normalized.body[1], `b`)
	expect_shape_normalized(t, normalized.trailing, `x`)
	expect_shape_rule(t, &normalized, `a x | b x`)
}

@(test)
test_normalize_rule_factors_nothing_when_nothing_is_shared :: proc(t: ^testing.T) {
	opts := Normalize_Options{}
	defer destroy_normalize_options(&opts)

	normalized, _ := normalize_one(t, `use = a | b;`, "use", &opts)
	defer destroy_normalized_rule(&normalized)

	expect_shape_normalized(t, normalized.leading, `nothing`)
	expect_shape_normalized(t, normalized.body[0], `a`)
	expect_shape_normalized(t, normalized.body[1], `b`)
	expect_shape_normalized(t, normalized.trailing, `nothing`)
	expect_shape_rule(t, &normalized, `a | b`)
}

// A leading is taken as far as it goes, so a branch it runs out of leaves an empty
// middle rather than a shorter leading.
@(test)
test_normalize_rule_leaves_a_branch_the_head_exhausts_empty :: proc(t: ^testing.T) {
	opts := Normalize_Options{}
	defer destroy_normalize_options(&opts)

	normalized, _ := normalize_one(t, `use = a b | a b c;`, "use", &opts)
	defer destroy_normalized_rule(&normalized)

	expect_shape_normalized(t, normalized.leading, `seq(a b)`)
	expect_body_len(t, &normalized, 2)
	expect_shape_normalized(t, normalized.body[0], `nothing`)
	expect_shape_normalized(t, normalized.body[1], `c`)
	expect_shape_rule(t, &normalized, `a b | a b c`)
}

// Only one branch is ever reachable, so a branch equal to one already kept is dead
// and dropping it cannot change what the rule matches.
@(test)
test_normalize_rule_drops_a_duplicate_branch :: proc(t: ^testing.T) {
	opts := Normalize_Options{}
	defer destroy_normalize_options(&opts)

	normalized, _ := normalize_one(t, `use = a | a | b;`, "use", &opts)
	defer destroy_normalized_rule(&normalized)

	expect_body_len(t, &normalized, 2)
	expect_shape_normalized(t, normalized.body[0], `a`)
	expect_shape_normalized(t, normalized.body[1], `b`)
	expect_shape_rule(t, &normalized, `a | b`)
}

// Branches that overlap without being equal are both kept, since whether the later
// one is reachable depends on whether a matcher backtracks into it.
@(test)
test_normalize_rule_keeps_branches_that_only_overlap :: proc(t: ^testing.T) {
	opts := Normalize_Options{}
	defer destroy_normalize_options(&opts)

	normalized, _ := normalize_one(t, `use = a | a b;`, "use", &opts)
	defer destroy_normalized_rule(&normalized)

	// The `a` both branches start with becomes the leading, and neither branch is
	// dropped for having the other as a prefix.
	expect_shape_normalized(t, normalized.leading, `a`)
	expect_body_len(t, &normalized, 2)
	expect_shape_normalized(t, normalized.body[0], `nothing`)
	expect_shape_normalized(t, normalized.body[1], `b`)
	expect_shape_normalized(t, normalized.trailing, `nothing`)
	expect_shape_rule(t, &normalized, `a | a b`)
}

@(test)
test_normalize_rule_gives_one_branch_when_every_branch_is_equal :: proc(t: ^testing.T) {
	opts := Normalize_Options{}
	defer destroy_normalize_options(&opts)

	normalized, _ := normalize_one(t, `use = a b | a b;`, "use", &opts)
	defer destroy_normalized_rule(&normalized)

	expect_body_len(t, &normalized, 1)
	expect_shape_normalized(t, normalized.leading, `nothing`)
	expect_shape_normalized(t, normalized.body[0], `seq(a b)`)
	expect_shape_normalized(t, normalized.trailing, `nothing`)
	expect_shape_rule(t, &normalized, `a b`)
}

@(test)
test_normalize_rule_gives_one_branch_without_alternatives :: proc(t: ^testing.T) {
	opts := Normalize_Options{}
	defer destroy_normalize_options(&opts)

	normalized, _ := normalize_one(t, `use = a b;`, "use", &opts)
	defer destroy_normalized_rule(&normalized)

	expect_body_len(t, &normalized, 1)
	expect_shape_normalized(t, normalized.leading, `nothing`)
	expect_shape_normalized(t, normalized.body[0], `seq(a b)`)
	expect_shape_normalized(t, normalized.trailing, `nothing`)
	expect_shape_rule(t, &normalized, `a b`)
}

// Factoring runs on the body an expansion produced, so a call that stood for a trailing
// is the trailing once it is inlined.
@(test)
test_normalize_rule_facts_an_expanded_body :: proc(t: ^testing.T) {
	opts := Normalize_Options{}
	defer destroy_normalize_options(&opts)

	normalized, ok := normalize_one(
		t,
		`
		wrap x = <item x>;
		item x = x q;
		use = <wrap "a"> | <wrap "b">;
		`,
		"use",
		&opts,
	)
	defer destroy_normalized_rule(&normalized)

	testing.expect(t, ok, "every call of use should expand")
	expect_shape_normalized(t, normalized.leading, `nothing`)
	expect_shape_normalized(t, normalized.body[0], `"a"`)
	expect_shape_normalized(t, normalized.body[1], `"b"`)
	expect_shape_normalized(t, normalized.trailing, `q`)
	expect_shape_rule(t, &normalized, `"a" q | "b" q`)
}

// An alternative inside a group, a repetition or an optional is factored too, since
// that is where a choice is written.
@(test)
test_normalize_rule_facts_a_nested_alternative :: proc(t: ^testing.T) {
	opts := Normalize_Options{}
	defer destroy_normalize_options(&opts)

	normalized, _ := normalize_one(t, `use = { x a | x b };`, "use", &opts)
	defer destroy_normalized_rule(&normalized)

	expect_body_len(t, &normalized, 1)
	expect_shape_normalized(t, normalized.body[0], `rep(factor(x | a | b ; nothing))`)
	expect_shape_rule(t, &normalized, `rep(factor(x | a | b ; nothing))`)
}

@(test)
test_normalize_rule_facts_a_nested_alternative_in_a_group_and_an_optional :: proc(
	t: ^testing.T,
) {
	opts := Normalize_Options{}
	defer destroy_normalize_options(&opts)

	normalized, _ := normalize_one(t, `use = ( y a | y b ) [ c | d ];`, "use", &opts)
	defer destroy_normalized_rule(&normalized)

	expect_shape_normalized(
		t,
		normalized.body[0],
		`seq(grp(factor(y | a | b ; nothing)) opt(factor(nothing | c | d ; nothing)))`,
	)
}

// A tag says nothing about the shape of a production, so by default it does not stop
// two branches from sharing one, and it does not survive factoring either.
@(test)
test_normalize_rule_strips_tags_by_default :: proc(t: ^testing.T) {
	opts := Normalize_Options{}
	defer destroy_normalize_options(&opts)

	normalized, _ := normalize_one(
		t,
		"use = a `name=\"x\"` | a `name=\"y\"`;",
		"use",
		&opts,
	)
	defer destroy_normalized_rule(&normalized)

	expect_body_len(t, &normalized, 1)
	expect_shape_normalized(t, normalized.body[0], `a`)
	expect_shape_rule(t, &normalized, `a`)
}

// A tag annotates the whole of the branch it closes, so stripping it does not merge
// branches whose annotated productions differ.
@(test)
test_normalize_rule_keeps_branches_apart_when_stripped :: proc(t: ^testing.T) {
	opts := Normalize_Options{}
	defer destroy_normalize_options(&opts)

	normalized, _ := normalize_one(
		t,
		"use = a b `name=\"x\"` | a c `name=\"y\"`;\n",
		"use",
		&opts,
	)
	defer destroy_normalized_rule(&normalized)

	expect_shape_normalized(t, normalized.leading, `nothing`)
	expect_body_len(t, &normalized, 2)
	expect_shape_normalized(t, normalized.body[0], `seq(a b)`)
	expect_shape_normalized(t, normalized.body[1], `seq(a c)`)
	expect_shape_rule(t, &normalized, `a b | a c`)
}

@(test)
test_normalize_rule_reports_a_tag_conflict :: proc(t: ^testing.T) {
	opts := Normalize_Options{tags = .Block}
	defer destroy_normalize_options(&opts)

	normalized, _ := normalize_one(t, "use = a `name=\"x\"`\n  | a `name=\"y\"`\n  ;\n", "use", &opts)
	defer destroy_normalized_rule(&normalized)

	expect_body_len(t, &normalized, 1)
	expect_shape_rule(t, &normalized, `a`)

	testing.expectf(t, len(opts.conflicts) == 1, "got %d conflicts, want 1", len(opts.conflicts))
	if len(opts.conflicts) == 1 {
		conflict := opts.conflicts[0]
		testing.expect(t, conflict.name == "name", "the differing pair is the one written")
		testing.expect(t, conflict.left == `"x"`, "one branch's value")
		testing.expect(t, conflict.right == `"y"`, "the other's")
	}
}

// .Keep counts tags, so two branches that tag the same production differently do not
// share it and both survive.
@(test)
test_normalize_rule_keeps_tags_and_both_branches :: proc(t: ^testing.T) {
	opts := Normalize_Options{tags = .Keep}
	defer destroy_normalize_options(&opts)

	normalized, _ := normalize_one(t, "use = a `name=\"x\"`\n  | a `name=\"y\"`\n  ;\n", "use", &opts)
	defer destroy_normalized_rule(&normalized)

	expect_shape_normalized(t, normalized.leading, `nothing`)
	expect_body_len(t, &normalized, 2)
	expect_shape_normalized(t, normalized.body[0], `tag(name="x" a)`)
	expect_shape_normalized(t, normalized.body[1], `tag(name="y" a)`)
	expect_shape_rule(t, &normalized, `a | a`)
	testing.expect(t, len(opts.conflicts) == 0, ".Keep reports nothing")
}

@(test)
test_normalize_rule_keeps_a_tag_both_branches_agree_on :: proc(t: ^testing.T) {
	opts := Normalize_Options{tags = .Keep}
	defer destroy_normalize_options(&opts)

	normalized, _ := normalize_one(
		t,
		"use = a `name=\"x\"` | a `name=\"x\"`;\n",
		"use",
		&opts,
	)
	defer destroy_normalized_rule(&normalized)

	expect_body_len(t, &normalized, 1)
	expect_shape_normalized(t, normalized.body[0], `tag(name="x" a)`)
	expect_shape_rule(t, &normalized, `a`)
}

// A call the expansion could not resolve is an element like any other to factoring,
// but ok says the normal form rests on an expansion that did not finish.
@(test)
test_normalize_rule_reports_an_unfinished_expansion :: proc(t: ^testing.T) {
	opts := Normalize_Options{}
	defer destroy_normalize_options(&opts)

	normalized, ok := normalize_one(t, `use = <nope "a"> x | <nope "a"> y;`, "use", &opts)
	defer destroy_normalized_rule(&normalized)

	testing.expect(t, !ok, "an undeclared callee cannot be expanded")
	expect_shape_normalized(t, normalized.leading, `call(nope, "a")`)
	expect_body_len(t, &normalized, 2)
	expect_shape_normalized(t, normalized.body[0], `x`)
	expect_shape_normalized(t, normalized.body[1], `y`)
	expect_shape_rule(t, &normalized, `call(nope, "a") x | call(nope, "a") y`)
}
