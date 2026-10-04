package ast

import "core:log"

// MAX_EXPANSION_DEPTH bounds how many calls in a row an expansion follows. Rules
// that call each other in a cycle would expand forever without it, so the bound is
// what makes expansion terminate. A call that reaches it is reported as left in
// place rather than dropped silently.
MAX_EXPANSION_DEPTH :: 256

// Nesting says what becomes of a production that an expansion turned into a
// sequence. Flatten splices it into the list it joins, which is what the parser
// does with unpack_sequence and what keeps one sequence from nesting inside
// another. Keep leaves it a single element, which an alternative needs, since the
// elements of an alternative are whole branches.
Nesting :: enum {
	Keep,
	Flatten,
}

// Scope is the set of rules an expansion resolves a call against.
Scope :: struct {
	rules_by_name: map[string]Rule,
}

// Normalized_Rule is a rule body split into the three parts a normal form is made
// of. The shape is not settled yet; see implementation/12-normalization.md.
Normalized_Rule :: struct {
	head: Production,
	body: Production,
	tail: Production,
}

lookup :: proc(s: ^Scope, n: string) -> (r: Rule, ok: bool) {
	rule := s.rules_by_name[n] or_return
	return rule, true
}

// get_rule returns the rule a call names. A qualified name names a rule of another
// namespace, which a scope over one namespace does not hold, so it is reported as
// unresolved rather than guessed at.
get_rule :: proc(name: Any_Ident, s: ^Scope) -> (r: Rule, ok: bool) {
	switch it in name {
	case Ident:
		return lookup(s, it.name)
	case Qual_Ident:
	}
	return {}, false
}

// expand_rule returns r with every call in its body replaced by the body of the
// rule that call names, and ok = false when a call is left in place because the
// scope does not declare the rule it names, or because the chain of calls is
// deeper than MAX_EXPANSION_DEPTH.
//
// The rule that comes back owns its parameter list and its body outright, so it
// shares nothing with r or with the scope: the scope may be expanded against
// again, and the same rule may be expanded more than once.
expand_rule :: proc(r: Rule, s: ^Scope) -> (Rule, bool) {
	body, ok := expand_production(clone_production(r.expr), s, MAX_EXPANSION_DEPTH)
	expanded := Rule {
		ident  = r.ident,
		params = clone_idents(r.params[:]),
		expr   = body,
		pos    = r.pos,
	}
	return expanded, ok
}

// destroy_rule frees a rule expand_rule returned.
destroy_rule :: proc(r: ^Rule) {
	delete(r.params)
	destroy_expr(r.expr)
}

// expand_production returns p with every call in it that the scope can resolve
// replaced by the body of the rule that call names, and ok = false when a call is
// left in place.
//
// It takes p over: the result is built from what p held and whatever p owned is
// freed along the way, so the caller must not use p afterwards and must not free it
// either. Ownership of the result passes to the caller, which frees it with
// destroy_expr.
//
// depth counts how many further calls in a row may be followed. Only a call spends
// one, so a rule that calls itself runs out of depth instead of expanding forever.
expand_production :: proc(p: Production, s: ^Scope, depth: int) -> (Production, bool) {
	switch it in p {
	case ^Call:
		return expand_call(it, s, depth)

	case Sequence:
		exprs, ok := expand_exprs(it.exprs[:], s, depth, .Flatten)
		delete(it.exprs)
		return Sequence{exprs = exprs, pos = it.pos}, ok

	case Alternative:
		exprs, ok := expand_exprs(it.exprs[:], s, depth, .Keep)
		delete(it.exprs)
		return Alternative{exprs = exprs, pos = it.pos}, ok

	case Optional:
		exprs, ok := expand_exprs(it.exprs[:], s, depth, .Flatten)
		delete(it.exprs)
		return Optional{exprs = exprs, pos = it.pos}, ok

	case Repetition:
		exprs, ok := expand_exprs(it.exprs[:], s, depth, .Flatten)
		delete(it.exprs)
		return Repetition{exprs = exprs, pos = it.pos}, ok

	case Group:
		exprs, ok := expand_exprs(it.exprs[:], s, depth, .Flatten)
		delete(it.exprs)
		return Group{exprs = exprs, pos = it.pos}, ok

	case Tagged_Production:
		expr, ok := expand_production(it.expr^, s, depth)
		tagged := new(Tagged_Production)
		tagged^ = it
		free(it.expr)
		tagged.expr = new(Production)
		tagged.expr^ = expr
		return tagged^, ok

	// A leaf holds nothing but its position and its view of the source, so there
	// is nothing to take over. A directive holds productions, but one only ever
	// appears in a binding, which has no body to expand.
	case Ident, String_Lit, Regex_Lit, External_Value, Qual_Ident, Directive:
		return p, true
	}

	return p, true
}

// expand_call returns the body of the rule a call names, with the call's arguments
// substituted for the callee's parameters, expanded in turn. A call the scope
// cannot resolve, or one that has already followed MAX_EXPANSION_DEPTH calls, comes
// back as it was, with ok = false. The call is taken over either way, so a call that
// is expanded is freed here and one that is kept becomes part of the result.
expand_call :: proc(call: ^Call, s: ^Scope, depth: int) -> (Production, bool) {
	if depth <= 0 {
		log.debugf("stopped expanding calls at %d: the chain is too deep", call.pos)
		return call, false
	}

	rule, ok := get_rule(call.ident, s)
	if !ok {
		log.debugf("stopped expanding a call at %d: the scope has no such rule", call.pos)
		return call, false
	}

	// A call that passes the wrong number of arguments is an error the checker has
	// already reported, so the arguments are paired off as far as they go and a
	// parameter left over keeps its own name in the body.
	args := make(map[string]Production, len(rule.params))
	defer delete(args)
	for i in 0 ..< min(len(rule.params), len(call.args)) {
		args[rule.params[i].name] = call.args[i]
	}

	// Substitution copies whatever it binds, so the arguments it borrowed are free
	// to go once it is done.
	body := substitute_parameter(clone_production(rule.expr), args)
	destroy_expr(call)

	return expand_production(body, s, depth - 1)
}

// expand_exprs expands every production of a body and returns them as a new list.
// nesting says whether a production that came back as a sequence joins the list or
// stands as one element of it.
expand_exprs :: proc(
	prods: []Production,
	s: ^Scope,
	depth: int,
	nesting: Nesting,
) -> ([dynamic]Production, bool) {
	exprs := make([dynamic]Production, 0, len(prods))
	ok := true
	for prod in prods {
		expanded, expanded_ok := expand_production(prod, s, depth)
		ok = ok && expanded_ok
		switch nesting {
		case .Keep:
			append(&exprs, expanded)
		case .Flatten:
			append_flattened(&exprs, expanded)
		}
	}
	return exprs, ok
}

// append_flattened appends e to exprs, splicing a sequence into the list instead of
// nesting one sequence inside another. The spliced list was made by expand_exprs,
// so it belongs to this expansion and is freed here.
append_flattened :: proc(exprs: ^[dynamic]Production, e: Production) {
	seq, is_sequence := e.(Sequence)
	if !is_sequence {
		append(exprs, e)
		return
	}
	for inner in seq.exprs {
		append(exprs, inner)
	}
	delete(seq.exprs)
}

// substitute_parameter returns p with every reference to one of args replaced by
// the production bound to it. The body it edits is a copy the caller owns, so it
// is edited in place, and a replacement is copied as it is made, so one argument
// standing in for the same parameter twice ends up in two places.
substitute_parameter :: proc(p: Production, args: map[string]Production) -> Production {
	switch it in p {
	case String_Lit, Regex_Lit, External_Value, Directive:
		return p

	case Ident:
		arg, is_bound := args[it.name]
		if !is_bound do return p
		return clone_production(arg)

	case Qual_Ident:
		// A member name is not a reference and never substitutes, but the receiver
		// of a member access is one.
		if receiver, is_bound := args[it.lhs.name]; is_bound {
			if ident, is_ident := receiver.(Ident); is_ident {
				member := it
				member.lhs = ident
				return member
			}
		}
		return p

	case Tagged_Production:
		prod := it
		prod.expr^ = substitute_parameter(it.expr^, args)
		return prod

	case Sequence:
		substitute_into(it.exprs[:], args)
		return it

	case Alternative:
		substitute_into(it.exprs[:], args)
		return it

	case Optional:
		substitute_into(it.exprs[:], args)
		return it

	case Repetition:
		substitute_into(it.exprs[:], args)
		return it

	case Group:
		substitute_into(it.exprs[:], args)
		return it

	case ^Call:
		substitute_into(it.args[:], args)
		it.ident = substitute_callee(it.ident, args)
		return it
	}

	return p
}

// substitute_into replaces every production of a body that references one of args.
substitute_into :: proc(prods: []Production, args: map[string]Production) {
	for prod, i in prods {
		prods[i] = substitute_parameter(prod, args)
	}
}

// substitute_callee returns the name of a call with a parameter substituted for the
// receiver of a qualified callee, as in `p ns = <ns.Rule "a">`. A bare parameter is
// left alone, since the callee of a call names a rule and a parameter there is a
// mistake the checker reports.
substitute_callee :: proc(name: Any_Ident, args: map[string]Production) -> Any_Ident {
	member, is_member := name.(Qual_Ident)
	if !is_member do return name
	if receiver, is_bound := args[member.lhs.name]; is_bound {
		if ident, is_ident := receiver.(Ident); is_ident {
			substituted := member
			substituted.lhs = ident
			return substituted
		}
	}
	return name
}

// clone_production returns a deep copy of p. A leaf holds only its position and its
// view of the source, so it is copied by value; everything else owns memory, whether
// in a dynamic array or behind a pointer, and is copied into fresh allocations,
// which leaves the copy independent of the original.
clone_production :: proc(p: Production) -> Production {
	switch it in p {
	case ^Call:
		call := new(Call)
		call^ = it^
		call.args = clone_exprs(it.args[:])
		return call
	case Tagged_Production:
		tagged := new(Tagged_Production)
		tagged^ = it
		tagged.expr = new(Production)
		tagged.expr^ = clone_production(it.expr^)
		return tagged^

	case Sequence:
		return Sequence{exprs = clone_exprs(it.exprs[:]), pos = it.pos}
	case Alternative:
		return Alternative{exprs = clone_exprs(it.exprs[:]), pos = it.pos}
	case Optional:
		return Optional{exprs = clone_exprs(it.exprs[:]), pos = it.pos}
	case Repetition:
		return Repetition{exprs = clone_exprs(it.exprs[:]), pos = it.pos}
	case Group:
		return Group{exprs = clone_exprs(it.exprs[:]), pos = it.pos}

	case Ident, String_Lit, Regex_Lit, External_Value, Qual_Ident, Directive:
		return p
	}

	return p
}

clone_exprs :: proc(prods: []Production) -> [dynamic]Production {
	cloned := make([dynamic]Production, 0, len(prods))
	for prod in prods {
		append(&cloned, clone_production(prod))
	}
	return cloned
}

has_call_any :: proc(prods: []Production) -> bool {
	for prod in prods {
		if has_call(prod) do return true
	}
	return false
}

has_call :: proc(p: Production) -> bool {
	switch it in p {
	case Ident, String_Lit, Regex_Lit, External_Value, Qual_Ident:
		return false

	case Sequence:
		return has_call_any(it.exprs[:])

	case Alternative:
		return has_call_any(it.exprs[:])

	case Optional:
		return has_call_any(it.exprs[:])

	case Repetition:
		return has_call_any(it.exprs[:])

	case Group:
		return has_call_any(it.exprs[:])

	case Directive:
	case Tagged_Production:
		return has_call(it.expr^)

	case ^Call:
		return true
	}
	return false
}
