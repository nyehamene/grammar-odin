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

// Normalized_Production is a production of the normalized tree: a production that
// stands for itself, an alternative that has been factored, or a production that
// holds productions, each of them normalized. A nil value is nothing at all, which
// is how an absent head or tail and an empty middle between a head and a tail are
// written.
Normalized_Production :: struct {
	kind: union {
		Nothing,
		Production,
		^Factored,
		^Grouped,
	},
}

// Nothing is the absence of a production: no common head, no common tail, and
// nothing left between them.
Nothing :: enum {
	absent,
}

// nothing returns an absent production. A zero Normalized_Production has a nil kind
// and reads as absent too, but saying so is clearer than relying on that.
nothing :: proc() -> Normalized_Production {
	return Normalized_Production{kind = Nothing.absent}
}

// Factored is an alternative split into the productions every branch shares at its
// start, the productions they do not share, and the productions every branch shares
// at its end. body holds one entry per surviving branch, in source order, and is
// what a consumer switches on; a nil entry is a branch the head and tail matched on
// their own. head and tail are nil when nothing is shared, so a rule with one branch
// or none factors to a body of a single entry and nothing else.
Factored :: struct {
	head: Normalized_Production,
	body: [dynamic]Normalized_Production,
	tail: Normalized_Production,
	pos:  int,
}

// Group_Shape is what a Grouped production wraps. A tag is one of them, since a
// tagged production holds the production it annotates.
Group_Shape :: enum {
	Sequence,
	Group,
	Optional,
	Repetition,
	Tagged,
}

// Grouped is a production that holds productions: a sequence, a group, an optional,
// a repetition or a tagged production, with every one of them normalized. One shape
// covers all of them so that the normalized tree adds one node rather than five.
Grouped :: struct {
	shape: Group_Shape,
	exprs: [dynamic]Normalized_Production,
	tag:   [dynamic]Tag_Pair, // only for .Tagged; nil otherwise
	pos:   int,
}

// Normalized_Rule is a rule whose body has been factored. It repeats the three
// fields of Factored rather than embedding it, so that the position of the rule
// does not collide with the position of the body.
Normalized_Rule :: struct {
	ident:  Ident,
	params: [dynamic]Ident,
	head:   Normalized_Production,
	body:   [dynamic]Normalized_Production,
	tail:   Normalized_Production,
	pos:    int,
}

// Tag_Policy says what factoring does with a tag. A tag names a production for a
// consumer that reads the grammar rather than describing its shape, so the default
// drops it.
Tag_Policy :: enum {
	// Strip compares and drops tags, so a tagged production is as common as the
	// production it annotates and the alternative is factored as far as it goes.
	Strip,
	// Block compares as Strip does but records every tag a shared element disagrees
	// on, for a caller that cannot afford to lose one quietly.
	Block,
	// Keep compares tags as part of the production, so two elements carrying
	// different tags are not common and the common prefix stops before them. Every
	// tag survives.
	Keep,
}

// Tag_Conflict is one tag that two branches give the same production differently.
// Factoring can resolve such a pair only by dropping one of them, which is what
// .Block exists to report rather than to do silently.
Tag_Conflict :: struct {
	pos:   int, // offset of the shared element the conflict is about
	name:  string, // the tag pair that differs
	left:  string, // the value one branch gives it, with its quotes
	right: string, // the value another branch gives it
}

// Normalize_Options carries the policy of one pass and what the pass found.
// conflicts belongs to the caller, which frees it with destroy_normalize_options.
Normalize_Options :: struct {
	tags:      Tag_Policy,
	conflicts: [dynamic]Tag_Conflict,
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
		// The node is a value in the union, so it is copied rather than pointed at:
		// only the box holding the production it annotates is replaced.
		expr, ok := expand_production(it.expr^, s, depth)
		tagged := it
		free(it.expr)
		tagged.expr = new(Production)
		tagged.expr^ = expr
		return tagged, ok

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
		tagged := it
		// The run of pairs is copied rather than shared: both the copy and the
		// original would otherwise free the one the parser allocated.
		tagged.tag = clone_tag_pairs(it.tag[:])
		tagged.expr = new(Production)
		tagged.expr^ = clone_production(it.expr^)
		return tagged

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

// clone_tag_pairs returns a copy of a run of tag pairs, so that a copy of a tagged
// production does not share the run with the one it was copied from.
clone_tag_pairs :: proc(pairs: []Tag_Pair) -> [dynamic]Tag_Pair {
	cloned := make([dynamic]Tag_Pair, len(pairs))
	for pair, i in pairs {
		cloned[i] = pair
	}
	return cloned
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

// normalize_rule returns r with its body factored: every alternative in the tree
// becomes the productions its branches share at the start, the productions they do
// not share, and the productions they share at the end.
//
// ok is false when the expansion the rule was normalized against did not finish. A
// call left in place is opaque to factoring, which treats it like any other element,
// so it may well sit in a common head; ok says the normal form rests on an expansion
// that is incomplete, not that the factoring is.
//
// The rule that comes back owns its parameter list and its body, and the caller
// frees it with destroy_normalized_rule.
normalize_rule :: proc(
	r: Rule,
	s: ^Scope,
	opts: ^Normalize_Options,
) -> (Normalized_Rule, bool) {
	expanded, ok := expand_rule(r, s)

	normalized := Normalized_Rule {
		ident  = r.ident,
		params = clone_idents(r.params[:]),
		head   = nothing(),
		tail   = nothing(),
		pos    = r.pos,
	}

	root := normalize_expr(expanded.expr, opts)

	#partial switch it in root.kind {
	case ^Factored:
		// The three parts move out and the node they were read from goes with them.
		normalized.head = it.head
		normalized.body = it.body
		normalized.tail = it.tail
		free(it)
	case:
		normalized.body = make([dynamic]Normalized_Production, 1)
		normalized.body[0] = root
	}
	return normalized, ok
}

// destroy_normalized_rule frees a rule normalize_rule returned.
destroy_normalized_rule :: proc(n: ^Normalized_Rule) {
	delete(n.params)
	destroy_normalized(&n.head)
	destroy_normalized_list(n.body[:])
	delete(n.body)
	destroy_normalized(&n.tail)
}

// destroy_normalize_options frees what a pass found.
destroy_normalize_options :: proc(opts: ^Normalize_Options) {
	delete(opts.conflicts)
}

// destroy_normalized frees a production of the normalized tree.
destroy_normalized :: proc(n: ^Normalized_Production) {
	if n.kind == nil do return
	switch it in n.kind {
	case Production:
		destroy_expr(it)
	case Nothing:
	case ^Factored:
		destroy_normalized(&it.head)
		destroy_normalized_list(it.body[:])
		delete(it.body)
		destroy_normalized(&it.tail)
		free(it)
	case ^Grouped:
		destroy_normalized_list(it.exprs[:])
		delete(it.exprs)
		delete(it.tag)
		free(it)
	}
}

destroy_normalized_list :: proc(prods: []Normalized_Production) {
	for i in 0 ..< len(prods) {
		destroy_normalized(&prods[i])
	}
}

// normalize_expr turns p into a production of the normalized tree. An alternative is
// factored, which is the one shape the normal form describes, and every other
// production that holds productions is rebuilt with what it holds normalized, so an
// alternative inside a group, a repetition, an optional or a tag is factored too.
// A call is a leaf: one only survives an expansion that did not finish, and the
// caller is told about it, so there is nothing to reach into it for.
//
// The tree p belongs to is taken over: every node ends up in the result and every
// array and box along the way is freed.
normalize_expr :: proc(p: Production, opts: ^Normalize_Options) -> Normalized_Production {
	switch it in p {
	case Alternative:
		return factor(it, opts)
	case Sequence:
		part := grouped(.Sequence, it.exprs[:], it.pos, opts, nil)
		delete(it.exprs)
		return part
	case Group:
		part := grouped(.Group, it.exprs[:], it.pos, opts, nil)
		delete(it.exprs)
		return part
	case Optional:
		part := grouped(.Optional, it.exprs[:], it.pos, opts, nil)
		delete(it.exprs)
		return part
	case Repetition:
		part := grouped(.Repetition, it.exprs[:], it.pos, opts, nil)
		delete(it.exprs)
		return part
	case Tagged_Production:
		return normalize_tagged(it, opts)

	// A leaf, and a call: one only survives an expansion that did not finish.
	case Ident, String_Lit, Regex_Lit, External_Value, Qual_Ident, Directive, ^Call:
	}
	return Normalized_Production{kind = p}
}

// grouped returns a production of the given shape holding exprs normalized. tag is
// handed over with it. The list belongs to the caller, which is why it is not freed
// here: it may be a slice of a longer one, and only the caller knows.
grouped :: proc(
	shape: Group_Shape,
	exprs: []Production,
	pos: int,
	opts: ^Normalize_Options,
	tag: [dynamic]Tag_Pair,
) -> Normalized_Production {
	parts := make([dynamic]Normalized_Production, 0, len(exprs))
	for expr in exprs {
		append(&parts, normalize_expr(expr, opts))
	}
	group := new(Grouped)
	group^ = Grouped {
		shape = shape,
		exprs = parts,
		tag   = tag,
		pos   = pos,
	}
	return Normalized_Production{kind = group}
}

// normalize_tagged returns the normalized production a tag annotates. A tag is
// dropped unless the policy keeps it, in which case it becomes part of the shape so
// that the pair survives with the production it names.
normalize_tagged :: proc(
	tagged: Tagged_Production,
	opts: ^Normalize_Options,
) -> Normalized_Production {
	inner := normalize_expr(tagged.expr^, opts)
	free(tagged.expr)

	if opts.tags != .Keep {
		delete(tagged.tag)
		return inner
	}

	parts := make([dynamic]Normalized_Production, 1)
	parts[0] = inner
	group := new(Grouped)
	group^ = Grouped {
		shape = .Tagged,
		exprs = parts,
		tag   = tagged.tag,
		pos   = tagged.pos,
	}
	return Normalized_Production{kind = group}
}

// normalized_list returns the one production a list of elements describes, with each
// element normalized. A single element stands alone, as it does in a parsed branch.
// An empty list is a middle that the head and the tail left between them, which the
// parser never writes but a factored alternative needs, and is nil: nothing sits
// between them.
//
// The list is taken over.
normalized_list :: proc(
	elems: []Production,
	pos: int,
	opts: ^Normalize_Options,
) -> Normalized_Production {
	if len(elems) == 0 do return nothing()
	if len(elems) == 1 do return normalize_expr(elems[0], opts)
	return grouped(.Sequence, elems, pos, opts, nil)
}

// factor splits an alternative into the productions every branch shares at its
// start, the productions they do not share, and the productions every branch shares
// at its end.
//
// A branch equal to one already kept is dropped. Only one branch is ever reachable,
// so a duplicate cannot change the language the rule denotes, and dropping it is what
// makes the body hold the smallest set of productions that differ. Branches that
// overlap without being equal are both kept: whether the later one is reachable at
// all depends on whether a matcher backtracks into it after an earlier branch
// matched, which nothing here decides.
//
// The alternative is taken over.
factor :: proc(alts: Alternative, opts: ^Normalize_Options) -> Normalized_Production {
	// A branch owns its list: unpack_sequence hands the sequence's own list over and
	// wraps anything else in a new one, so every list here has exactly one owner.
	branches := make([dynamic][dynamic]Production, 0, len(alts.exprs))
	for branch in alts.exprs[:] {
		append(&branches, unpack_sequence(branch))
	}
	delete(alts.exprs)

	kept := make([dynamic][dynamic]Production, 0, len(branches))
	for branch in branches {
		if holds_equal_branch(kept[:], branch[:], opts) {
			destroy_expr_list(branch[:])
			delete(branch)
			continue
		}
		append(&kept, branch)
	}
	delete(branches)

	// Nothing is shared when one branch is left, whether the rule wrote no `|` or
	// every branch it wrote was a duplicate of another.
	if len(kept) < 2 {
		factored := new(Factored)
		factored^ = Factored {
			head = nothing(),
			body = make([dynamic]Normalized_Production, 1),
			tail = nothing(),
			pos  = alts.pos,
		}
		factored.body[0] = normalized_list(kept[0][:], alts.pos, opts)
		delete(kept[0])
		delete(kept)
		return Normalized_Production{kind = factored}
	}

	head_len := common_prefix_len(kept[:], opts)

	residuals := make([dynamic][]Production, len(kept))
	for b, i in kept {
		residuals[i] = kept[i][head_len:]
	}
	// The tail is the common suffix of what the head left, which stops at the
	// shortest remainder, so head and tail cannot overlap. The head is maximal, so
	// that already follows; going through the common suffix keeps it true by
	// construction rather than by the order of two steps.
	tail_len := common_suffix_len(residuals[:], opts)

	factored := new(Factored)
	factored^ = Factored {
		head = normalized_list(kept[0][:head_len], alts.pos, opts),
		tail = nothing(),
		pos  = alts.pos,
	}
	factored.tail = normalized_list(residuals[0][len(residuals[0])-tail_len:], alts.pos, opts)
	factored.body = make([dynamic]Normalized_Production, 0, len(residuals))
	for i in 0 ..< len(residuals) {
		middle := residuals[i][:len(residuals[i])-tail_len]
		append(&factored.body, normalized_list(middle, alts.pos, opts))
	}

	// Every branch but the first lent its head and its tail to a duplicate of what
	// the shared head and the shared tail already hold, so those productions are
	// freed instead of left behind. Its middle moved into body above.
	for i in 1 ..< len(kept) {
		destroy_expr_list(kept[i][:head_len])
		destroy_expr_list(residuals[i][len(residuals[i])-tail_len:])
		delete(kept[i])
	}
	delete(kept[0])
	delete(residuals)
	delete(kept)

	return Normalized_Production{kind = factored}
}

// holds_equal_branch reports whether branches already holds a branch equal to one.
holds_equal_branch :: proc(
	branches: [][dynamic]Production,
	branch: []Production,
	opts: ^Normalize_Options,
) -> bool {
	for other in branches {
		if equal_production_list(other[:], branch, opts) do return true
	}
	return false
}

// common_prefix_len returns how many productions the start of every branch shares.
common_prefix_len :: proc(branches: [][dynamic]Production, opts: ^Normalize_Options) -> int {
	n := 0
	shortest := len(branches[0])
	for b in branches[1:] {
		if len(b) < shortest do shortest = len(b)
	}
	for n < shortest {
		shared := true
		for b in branches[1:] {
			if !equal_production(branches[0][n], b[n], opts) {
				shared = false
				break
			}
		}
		if !shared do break
		n += 1
	}
	return n
}

// common_suffix_len returns how many productions the end of every branch shares. It
// stops at the shortest branch, which is what keeps a common tail from running into
// a common head.
common_suffix_len :: proc(branches: [][]Production, opts: ^Normalize_Options) -> int {
	n := 0
	shortest := len(branches[0])
	for b in branches[1:] {
		if len(b) < shortest do shortest = len(b)
	}
	for n < shortest {
		shared := true
		for b in branches[1:] {
			if !equal_production(last_of(branches[0], n), last_of(b, n), opts) {
				shared = false
				break
			}
		}
		if !shared do break
		n += 1
	}
	return n
}

// last_of returns the production back places from the end of branch.
last_of :: proc(branch: []Production, back: int) -> Production {
	return branch[len(branch)-1-back]
}

equal_production_list :: proc(
	a, b: []Production,
	opts: ^Normalize_Options,
) -> bool {
	if len(a) != len(b) do return false
	for prod, i in a {
		if !equal_production(prod, b[i], opts) do return false
	}
	return true
}

// equal_production reports whether a and b are the same production for the purpose
// of factoring, ignoring positions: two identical productions on different lines are
// the same one. Productions of different shapes are never equal.
//
// A tag names a production rather than describing it, so under .Strip and .Block only
// the production a tag annotates counts and two tags on the same production are the
// same production. Under .Keep the tags count too, which is what makes a differing
// tag stop a common prefix instead of resolving one quietly.
equal_production :: proc(a, b: Production, opts: ^Normalize_Options) -> bool {
	switch x in a {
	case Ident:
		y, ok := b.(Ident)
		return ok && x.name == y.name
	case String_Lit:
		y, ok := b.(String_Lit)
		return ok && x.value == y.value
	case Regex_Lit:
		y, ok := b.(Regex_Lit)
		return ok && x.value == y.value
	case External_Value:
		y, ok := b.(External_Value)
		return ok && x.name == y.name
	case Qual_Ident:
		y, ok := b.(Qual_Ident)
		return ok && x.lhs.name == y.lhs.name && x.rhs.name == y.rhs.name
	case Sequence:
		y, ok := b.(Sequence)
		return ok && equal_production_list(x.exprs[:], y.exprs[:], opts)
	case Alternative:
		y, ok := b.(Alternative)
		return ok && equal_production_list(x.exprs[:], y.exprs[:], opts)
	case Optional:
		y, ok := b.(Optional)
		return ok && equal_production_list(x.exprs[:], y.exprs[:], opts)
	case Repetition:
		y, ok := b.(Repetition)
		return ok && equal_production_list(x.exprs[:], y.exprs[:], opts)
	case Group:
		y, ok := b.(Group)
		return ok && equal_production_list(x.exprs[:], y.exprs[:], opts)
	case Directive:
		y, ok := b.(Directive)
		return ok && x.ident.name == y.ident.name
	case ^Call:
		y, ok := b.(^Call)
		if !ok do return false
		if !equal_name(x.ident, y.ident) do return false
		return equal_production_list(x.args[:], y.args[:], opts)
	case Tagged_Production:
		y, ok := b.(Tagged_Production)
		if !ok do return false
		if !equal_production(x.expr^, y.expr^, opts) do return false
		switch opts.tags {
		case .Strip:
			return true
		case .Block:
			if !equal_tag(x.tag[:], y.tag[:]) do record_tag_conflict(x, y, opts)
			return true
		case .Keep:
			return equal_tag(x.tag[:], y.tag[:])
		}
	}
	return false
}

equal_name :: proc(a, b: Any_Ident) -> bool {
	switch x in a {
	case Ident:
		y, ok := b.(Ident)
		return ok && x.name == y.name
	case Qual_Ident:
		y, ok := b.(Qual_Ident)
		return ok && x.lhs.name == y.lhs.name && x.rhs.name == y.rhs.name
	}
	return false
}

// equal_tag reports whether two runs of tag pairs are the same, ignoring positions.
equal_tag :: proc(a, b: []Tag_Pair) -> bool {
	if len(a) != len(b) do return false
	for pair, i in a {
		if pair.ident.name != b[i].ident.name do return false
		if pair.value.value != b[i].value.value do return false
	}
	return true
}

// record_tag_conflict notes the first tag two tagged productions disagree on, once
// per shared element however many comparisons find it.
record_tag_conflict :: proc(a, b: Tagged_Production, opts: ^Normalize_Options) {
	pairs := a.tag[:]
	for pair, i in pairs {
		disagrees :=
			i >= len(b.tag) ||
			pair.ident.name != b.tag[i].ident.name ||
			pair.value.value != b.tag[i].value.value
		if !disagrees do continue

		for seen in opts.conflicts[:] {
			if seen.pos == pair.pos && seen.name == pair.ident.name do return
		}
		right := ""
		if i < len(b.tag) do right = b.tag[i].value.value
		append(
			&opts.conflicts,
			Tag_Conflict {
				pos   = pair.pos,
				name  = pair.ident.name,
				left  = pair.value.value,
				right = right,
			},
		)
		return
	}
}

// destroy_expr_list frees every production of a list. The list itself belongs to
// whoever allocated it.
destroy_expr_list :: proc(prods: []Production) {
	for prod in prods do destroy_expr(prod)
}
