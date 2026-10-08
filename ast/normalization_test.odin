package ast

import "core:strings"
import "core:testing"

// scope_of returns the proc scope holding the procs of file. The scope shares the
// rules the file holds, so the file has to outlive it. The caller owns the scope and
// frees it with Destroy_Scope.
scope_of :: proc(file: ^File) -> Scope {
	rules := make([dynamic]Rule, len(file.decls), file.allocator)
	defer delete(rules)
	for decl in file.decls {
		rule := decl.(Rule) or_continue
		append(&rules, rule)
	}
	return Build_Scope(rules[:], file.allocator)
}

// rule_named returns the rule named name among the declarations of file. It shares
// the rule rather than copying it, so the file has to outlive the result.
rule_named :: proc(t: ^testing.T, file: ^File, name: string) -> Rule {
	for decl in file.decls {
		rule, is_rule := decl.(Rule)
		if is_rule && rule.ident.name == name do return rule
	}
	testing.fail_now(t, strings.concatenate({"the fixture declares no rule named ", name}))
}

// expand_one parses source, expands the rule named name against every proc source
// declares, and returns the expanded rule, whether every call in it was expanded,
// and the scope it was expanded against. source has to parse cleanly.
//
// The caller owns all three: the rule with destroy_rule, the scope with
// Destroy_Scope.
expand_one :: proc(t: ^testing.T, source, name: string) -> (Rule, bool, Scope) {
	file := must_parse(t, source)
	defer destroy_file(&file)

	scope := scope_of(&file)
	expanded, ok := expand_rule(rule_named(t, &file, name), &scope)
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
		shape_group(b, "seq", it.productions)
	case ^Alternative:
		// The chain leans left, so it prints as a nested choice.
		strings.write_string(b, "alt(")
		shape_into(b, it.lhs)
		strings.write_rune(b, ' ')
		shape_into(b, it.rhs)
		strings.write_rune(b, ')')
	case ^Optional:
		strings.write_string(b, "opt(")
		shape_into(b, it.production)
		strings.write_rune(b, ')')
	case ^Repetition:
		strings.write_string(b, "rep(")
		shape_into(b, it.production)
		strings.write_rune(b, ')')
	case ^Group:
		strings.write_string(b, "grp(")
		shape_into(b, it.production)
		strings.write_rune(b, ')')
	case ^Tagged_Production:
		strings.write_string(b, "tag(")
		shape_into(b, it.production)
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
	defer Destroy_Scope(&scope)

	testing.expect(t, ok, "every call of call_site should expand")
	testing.expect(t, !has_call(expanded.production), "an expanded rule holds no call")
	expect_shape(t, expanded.production, `seq("p" rep("p") "q" "z")`)
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
	defer Destroy_Scope(&scope)

	first, ok_first := expand_rule(rule_named(t, &file, "first"), &scope)
	defer destroy_rule(&first)
	testing.expect(t, ok_first, "every call of first should expand")
	expect_shape(t, first.production, `seq("a" rep("a"))`)

	second, ok_second := expand_rule(rule_named(t, &file, "second"), &scope)
	defer destroy_rule(&second)
	testing.expect(t, ok_second, "every call of second should expand")
	expect_shape(t, second.production, `seq("b" rep("b"))`)
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
	defer Destroy_Scope(&scope)

	expect_shape(t, first.production, `seq("a" rep("a"))`)
}

// A call the scope cannot resolve is reported rather than dropped, and is left in
// the body so that the caller can say which call it was.
@(test)
test_expand_rule_reports_a_call_it_cannot_resolve :: proc(t: ^testing.T) {
	expanded, ok, scope := expand_one(t, `use = <nope "a">;`, "use")
	defer destroy_rule(&expanded)
	defer Destroy_Scope(&scope)

	testing.expect(t, !ok, "an undeclared callee cannot be expanded")
	expect_shape(t, expanded.production, `call(nope, "a")`)
}

// A name may be declared as procs of several arities, and a call picks the one
// whose arity is the number of arguments it passes. Before this, the last
// declaration of a name won and every call went to it, so a call of one arity
// expanded against a proc of another.
@(test)
test_a_call_picks_the_proc_of_its_arity :: proc(t: ^testing.T) {
	expanded, ok, scope := expand_one(
		t,
		`
		pair x y = x y;
		one x = x;
		a = <one "a">;
		b = <pair "b" "c">;
		`,
		"b",
	)
	defer destroy_rule(&expanded)
	defer Destroy_Scope(&scope)

	testing.expect(t, ok, "every call of b should expand")
	expect_shape(t, expanded.production, `seq("b" "c")`)
}

// A rule declares no parameters, so it is not a proc and a call does not name it.
// The checker reports that as not callable; expansion reports it the way it
// reports any call it cannot resolve and leaves the call in place.
@(test)
test_a_call_does_not_reach_a_rule :: proc(t: ^testing.T) {
	expanded, ok, scope := expand_one(t, `item = "i"; use = <item>;`, "use")
	defer destroy_rule(&expanded)
	defer Destroy_Scope(&scope)

	testing.expect(t, !ok, "a rule is not callable")
	expect_shape(t, expanded.production, `call(item)`)
}

// A call whose arity no proc of that name answers to cannot be bound to any of
// them, so it is left in place rather than paired off against the closest arity.
@(test)
test_a_call_of_an_arity_no_proc_has_is_reported :: proc(t: ^testing.T) {
	expanded, ok, scope := expand_one(t, `one x = x; two x y = x y; use = <one "a" "b">;`, "use")
	defer destroy_rule(&expanded)
	defer Destroy_Scope(&scope)

	testing.expect(t, !ok, "no proc of that name takes that many arguments")
	expect_shape(t, expanded.production, `call(one, "a", "b")`)
}

// A name and an arity together name one proc, so a repeat of both keeps the first
// declaration. The checker is what reports it.
@(test)
test_build_scope_keeps_the_first_proc_of_an_arity :: proc(t: ^testing.T) {
	file := must_parse(t, `
		p x = "first";
		p a = "second";
		p x y = "third";
		use = <p "z">;
		`)
	defer destroy_file(&file)

	scope := scope_of(&file)
	defer Destroy_Scope(&scope)

	procs := scope.procs_by_name["p"]
	testing.expect_value(t, len(procs), 2)

	one, has_one := lookup_proc(&scope, "p", 1)
	testing.expect(t, has_one, "the arity 1 proc is declared")
	expect_shape(t, one.production, `"first"`)

	two, has_two := lookup_proc(&scope, "p", 2)
	testing.expect(t, has_two, "the arity 2 proc is declared")
	expect_shape(t, two.production, `"third"`)

	testing.expect_value(t, len(procs[0].params), 1)
	testing.expect_value(t, len(procs[1].params), 2)
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
	defer Destroy_Scope(&scope)

	testing.expect(t, !ok, "a callee of another namespace cannot be expanded")
	expect_shape(t, expanded.production, `call(Z.Rule, "a")`)
}

// Rules that call each other never run out of calls, so the depth bound is what
// ends the expansion.
@(test)
test_expand_rule_stops_on_a_cycle :: proc(t: ^testing.T) {
	expanded, ok, scope := expand_one(t, `loop x = <loop x>;`, "loop")
	defer destroy_rule(&expanded)
	defer Destroy_Scope(&scope)

	testing.expect(t, !ok, "a cycle of calls cannot be expanded")
	testing.expect(t, has_call(expanded.production), "the call is left in place")
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
	defer Destroy_Scope(&scope)

	// `target` stands in for `ns`, so the call names another rule of another
	// namespace and is the one thing left in the body.
	testing.expect(t, !ok, "a callee of another namespace cannot be expanded")
	expect_shape(t, expanded.production, `call(target.Rule)`)
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
	defer Destroy_Scope(&scope)

	testing.expect(t, ok, "every call of choice should expand")
	expect_shape(t, expanded.production, `alt(seq("a" "b") "c")`)
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
	defer Destroy_Scope(&scope)

	return normalize_rule(rule_named(t, &file, name), &scope, opts)
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
		for part in it.body {
			strings.write_string(b, " | ")
			shape_normalized_into(b, part)
		}
		strings.write_string(b, " ; ")
		shape_normalized_into(b, it.trailing)
		strings.write_rune(b, ')')
	case ^Grouped:
		switch it.shape {
		case .Sequence:
			shape_normalized_group(b, "seq", it.productions)
		case .Group:
			shape_normalized_group(b, "grp", it.productions)
		case .Optional:
			shape_normalized_group(b, "opt", it.productions)
		case .Repetition:
			shape_normalized_group(b, "rep", it.productions)
		case .Tagged:
			strings.write_string(b, "tag(")
			for pair, i in it.tag {
				if i > 0 do strings.write_rune(b, ' ')
				strings.write_string(b, pair.ident.name)
				strings.write_rune(b, '=')
				strings.write_string(b, pair.value.value)
			}
			for production in it.productions {
				strings.write_rune(b, ' ')
				shape_normalized_into(b, production)
			}
			strings.write_rune(b, ')')
		}
	}
}

shape_normalized_group :: proc(
	b: ^strings.Builder,
	label: string,
	productions: []Normalized_Production,
) {
	strings.write_string(b, label)
	strings.write_rune(b, '(')
	for production, i in productions {
		if i > 0 do strings.write_rune(b, ' ')
		shape_normalized_into(b, production)
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
			for production in it.productions do branch_shapes_into(b, production)
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

	for middle, i in n.body {
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

// .Merge combines the pairs two branches give the same production, so one branch is
// left. A pair name they give different values cannot hold both, which is the one
// thing merging has to resolve rather than combine, and it resolves it the way .Block
// does: by keeping the first value and saying so.
@(test)
test_normalize_rule_merges_tag_pairs_and_reports_a_conflicting_value :: proc(t: ^testing.T) {
	opts := Normalize_Options{tags = .Merge}
	defer destroy_normalize_options(&opts)

	normalized, _ := normalize_one(t, "use = a `name=\"x\"`\n  | a `name=\"y\"`\n  ;\n", "use", &opts)
	defer destroy_normalized_rule(&normalized)

	expect_shape_normalized(t, normalized.leading, `nothing`)
	expect_body_len(t, &normalized, 1)
	expect_shape_rule(t, &normalized, `a`)

	testing.expectf(t, len(opts.conflicts) == 1, "got %d conflicts, want 1", len(opts.conflicts))
	if len(opts.conflicts) == 1 {
		conflict := opts.conflicts[0]
		testing.expect(t, conflict.name == "name", "the differing pair is the one written")
		testing.expect(t, conflict.left == `"x"`, "the value that was kept")
		testing.expect(t, conflict.right == `"y"`, "the other's")
	}
}

// Pair names the branches do not share are not a contradiction, so under .Merge they
// are combined rather than reported.
@(test)
test_normalize_rule_merges_differing_pair_names_without_reporting_one :: proc(t: ^testing.T) {
	opts := Normalize_Options{tags = .Merge}
	defer destroy_normalize_options(&opts)

	normalized, _ := normalize_one(t, "use = a `kind=\"x\"`\n  | a `name=\"y\"`\n  ;\n", "use", &opts)
	defer destroy_normalized_rule(&normalized)

	expect_body_len(t, &normalized, 1)
	testing.expect(t, len(opts.conflicts) == 0, ".Merge combines names, so it reports none")
}

// A tag closes the production it annotates, so it annotates whatever that production
// turns out to be, the whole branch here. Two runs of pairs therefore meet only where
// two whole branches are one branch, which is where merging happens.
@(test)
test_normalize_rule_merges_nothing_when_the_branches_stay_apart :: proc(t: ^testing.T) {
	opts := Normalize_Options{tags = .Merge}
	defer destroy_normalize_options(&opts)

	normalized, _ := normalize_one(t, "use = a b `kind=\"x\"`\n  | a c `name=\"y\"`\n  ;\n", "use", &opts)
	defer destroy_normalized_rule(&normalized)

	expect_shape_normalized(t, normalized.leading, `nothing`)
	expect_body_len(t, &normalized, 2)
	expect_shape_normalized(t, normalized.body[0], `tag(kind="x" seq(a b))`)
	expect_shape_normalized(t, normalized.body[1], `tag(name="y" seq(a c))`)
	testing.expect(t, len(opts.conflicts) == 0, "the branches are different, so they disagree on nothing")
}

// The same rule without the tags has a leading to factor, and keeps one: the tag is
// what stops the branches from being common, not the productions they annotate.
@(test)
test_normalize_rule_factors_the_leading_of_two_untagged_branches :: proc(t: ^testing.T) {
	opts := Normalize_Options{tags = .Merge}
	defer destroy_normalize_options(&opts)

	normalized, _ := normalize_one(t, "use = a b\n  | a c\n  ;\n", "use", &opts)
	defer destroy_normalized_rule(&normalized)

	expect_shape_normalized(t, normalized.leading, `a`)
	expect_body_len(t, &normalized, 2)
	expect_shape_normalized(t, normalized.body[0], `b`)
	expect_shape_normalized(t, normalized.body[1], `c`)
}

// tagged_pair builds one `name="value"` pair for a test.
tagged_pair :: proc(name, value: string) -> Tag_Pair {
	return Tag_Pair {
		ident = Ident{name = name},
		value = String_Lit{value = value},
	}
}

// annotated builds a production annotating name with pairs, for a test. The caller
// owns what it ends up holding, which destroy_tagged frees.
annotated :: proc(name: string, pairs: ..Tag_Pair) -> Production {
	run := make([]Tag_Pair, len(pairs))
	for pair, i in pairs {
		run[i] = pair
	}
	// pairs is the caller's variadic slice, not ours to free.

	return tagged_production(Production(Ident{name = name}), run, 0)
}

// destroy_tagged frees a production made by annotated: the production it annotates,
// and the run of pairs on the node that holds them.
destroy_tagged :: proc(prod: Production) {
	tagged, is_tagged := prod.(^Tagged_Production)
	if !is_tagged do return
	destroy_production(tagged.production)
	delete(tagged.tag)
	free(tagged)
}

// Merging adds a pair that is not there yet and keeps one that is, so that which
// branch the pair came from does not change what is written.
@(test)
test_merge_tag_into_combines_pairs_and_keeps_the_first_value :: proc(t: ^testing.T) {
	dst := annotated("a", tagged_pair("kind", "x"), tagged_pair("u", "u"))
	defer destroy_tagged(dst)
	src := annotated("a", tagged_pair("kind", "y"), tagged_pair("name", "y"))
	defer destroy_tagged(src)

	opts := Normalize_Options{tags = .Merge}
	defer destroy_normalize_options(&opts)

	merge_tag_into(&dst, src, &opts)

	into := dst.(^Tagged_Production)
	testing.expectf(t, len(into.tag) == 3, "got %d pairs, want 3", len(into.tag))
	testing.expect(t, into.tag[0].ident.name == "kind", "the pair dst had comes first")
	testing.expect(t, into.tag[0].value.value == "x", "and keeps its value")
	testing.expect(t, into.tag[1].ident.name == "u", "the other pair dst had is kept")
	testing.expect(t, into.tag[2].ident.name == "name", "and the one src had is added")

	// The other policies drop the tags on the way out, so there is nothing to combine
	// and nothing is allocated to do it.
	stripped := Normalize_Options{tags = .Strip}
	defer destroy_normalize_options(&stripped)

	other := annotated("a", tagged_pair("kind", "x"))
	defer destroy_tagged(other)
	merge_tag_into(&other, src, &stripped)

	testing.expectf(
		t,
		len(other.(^Tagged_Production).tag) == 1,
		"got %d pairs, want 1",
		len(other.(^Tagged_Production).tag),
	)
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
