package ast

import "core:mem"

// Production is any production that can appear in a grammar.
Production :: union {
	Ident,
	String_Lit,
	Regex_Lit,
	External_Value,
	Qual_Ident,
	Directive,
	Sequence,
	^Alternative,
	^Optional,
	^Repetition,
	^Group,
	^Tagged_Production,
	^Call,
}

// Decl is any top-level declaration in a grammar file.
Decl :: union {
	Rule,
	Binding,
	Comment_Group,
}

// File is the root node of a parsed grammar source.
//
// A slice does not carry the allocator it was made with, unlike a dynamic array, so
// freeing one takes the allocator rather than finding it. The file keeps the allocator
// the parser built it with, which is what destroy_file frees it with.
File :: struct {
	decls:     []Decl,
	end_pos:   int,
	allocator: mem.Allocator,
}

// Rule is a named production, optionally with parameters. A rule names one
// production, so a body of more than one element is a Sequence.
//   greeting            = "Hello";
//   greet name title    = "hello" name title;
Rule :: struct {
	ident:      Ident,
	params:     []Ident,
	production: Production,
	pos:        int,
}

// Binding imports an external grammar file.
//   f = @import("../foo");
Binding :: struct {
	ident:     Ident,
	path:      String_Lit,
	directive: Directive,
	pos:       int,
}

// Comment_Group is a run of consecutive comments.
Comment_Group :: struct {
	list: []Comment,
	pos:  int,
}

Comment :: struct {
	pos:  int,
	text: string,
}

// Ident is an identifier.
Ident :: struct {
	pos:  int,
	name: string,
}

// String_Lit is a string literal, including its surrounding quotes in value.
String_Lit :: struct {
	pos:   int,
	value: string,
}

// Regex_Lit is a regexp literal, including its surrounding quotes in value.
Regex_Lit :: struct {
	pos:   int,
	value: string,
}

// External_Value references an external value, e.g. __name__.
External_Value :: struct {
	pos:  int,
	name: string,
}

// Sequence is a sequence of productions, e.g. `a b c`.
Sequence :: struct {
	productions: []Production,
	pos:         int,
}

// Alternative is a choice between two productions, e.g. `a | b`. A run of them
// is a chain leaning left, so `a | b | c` is `( a | b ) | c`, and a branch in
// parentheses is a Group rather than part of the chain.
Alternative :: struct {
	lhs: Production,
	rhs: Production,
	pos: int,
}

// Optional is a zero-or-one production, e.g. `[ a b ]`.
Optional :: struct {
	production: Production,
	pos:        int,
}

// Repetition is a zero-or-more production, e.g. `{ one two }`.
Repetition :: struct {
	production: Production,
	pos:        int,
}

// Group is a grouped production, e.g. `( a b )`.
Group :: struct {
	production: Production,
	pos:        int,
}

// Qual_Ident is a member access, e.g. `foo.bar`. It is left-associative, so
// `a.b` is Qual_Ident{a, b}.
Qual_Ident :: struct {
	lhs: Ident,
	rhs: Ident,
	pos: int,
}

Any_Ident :: union {
	Ident,
	Qual_Ident,
}

// Call is a call to a rule with arguments, e.g. `<greet person "Mr">`.
Call :: struct {
	// name: Production,
	ident: Any_Ident,
	args:  []Production,
	pos:   int,
}

// Directive is a directive, e.g. `@import("base")`.
Directive :: struct {
	ident: Ident,
	args:  []Production,
	pos:   int,
}

// Tagged_Production is a production annotated with one or more tags, e.g.
// `a b `name="value"``. pos is the offset of the annotated production, so the
// production reports the position of the element it wraps rather than that of
// the tag written after it.
Tagged_Production :: struct {
	production: Production,
	tag:        []Tag_Pair,
	pos:        int,
}

// The five kinds below are members of the union as pointers, because each of them
// holds a Production and a union cannot hold itself by value. That makes building one
// an allocation, so each is built here rather than at the places that want one.

// alternative returns a choice between two productions. A run of them is a chain
// leaning left, so `a | b | c` is `( a | b ) | c`.
alternative :: proc(lhs, rhs: Production, pos: int, allocator := context.allocator) -> Production {
	node := new(Alternative, allocator)
	node.lhs = lhs
	node.rhs = rhs
	node.pos = pos
	return node
}

// optional returns a zero-or-one production, e.g. `[ a b ]`.
optional :: proc(production: Production, pos: int, allocator := context.allocator) -> Production {
	node := new(Optional, allocator)
	node.production = production
	node.pos = pos
	return node
}

// repetition returns a zero-or-more production, e.g. `{ one two }`.
repetition :: proc(
	production: Production,
	pos: int,
	allocator := context.allocator,
) -> Production {
	node := new(Repetition, allocator)
	node.production = production
	node.pos = pos
	return node
}

// group returns a grouped production, e.g. `( a b )`.
group :: proc(production: Production, pos: int, allocator := context.allocator) -> Production {
	node := new(Group, allocator)
	node.production = production
	node.pos = pos
	return node
}

// tagged_production returns a production annotated with one or more tags.
tagged_production :: proc(
	production: Production,
	tag: []Tag_Pair,
	pos: int,
	allocator := context.allocator,
) -> Production {
	node := new(Tagged_Production, allocator)
	node.production = production
	node.tag = tag
	node.pos = pos
	return node
}

// Tag_Pair is one `name="value"` entry of a tag. value keeps its quotes, like
// String_Lit.
Tag_Pair :: struct {
	ident: Ident,
	value: String_Lit,
	pos:   int,
}

// Error is a syntax diagnostic produced by the parser.
Error :: struct {
	offset:  int,
	message: string,
}

// production_pos returns the source offset of the first token of production.
production_pos :: proc(production: Production) -> int {
	switch v in production {
	case Ident:
		return v.pos
	case String_Lit:
		return v.pos
	case Regex_Lit:
		return v.pos
	case External_Value:
		return v.pos
	case Sequence:
		return v.pos
	case ^Alternative:
		return v.pos
	case ^Optional:
		return v.pos
	case ^Repetition:
		return v.pos
	case ^Group:
		return v.pos
	case Qual_Ident:
		return v.pos
	case ^Call:
		return v.pos
	case Directive:
		return v.pos
	case ^Tagged_Production:
		return v.pos
	}
	return 0
}

// decl_pos returns the source offset of the first token of decl.
decl_pos :: proc(decl: Decl) -> int {
	switch v in decl {
	case Rule:
		return v.pos
	case Binding:
		return v.pos
	case Comment_Group:
		return v.pos
	}
	return 0
}

// A node holds its lists as slices rather than as dynamic arrays, because a slice can
// be freed with the allocator it was built with and a dynamic array cannot. A list
// whose length is known before it is built is allocated as a slice and filled in
// place. One whose length is only known once it has been read is accumulated in a
// dynamic array and copied into a slice of exactly its length by one of the three
// below, once the node that owns it is built. The dynamic array stays with whoever
// built it: a list handed to a node has already been taken over by that builder.

// to_slice_decls copies a working list into a slice of exactly its length.
to_slice_decls :: proc(list: [dynamic]Decl, allocator := context.allocator) -> []Decl {
	sliced := make([]Decl, len(list), allocator)
	copy(sliced, list[:])
	return sliced
}

// to_slice_comments copies a working list into a slice of exactly its length.
to_slice_comments :: proc(
	list: [dynamic]Comment,
	allocator := context.allocator,
) -> []Comment {
	sliced := make([]Comment, len(list), allocator)
	copy(sliced, list[:])
	return sliced
}

// to_slice_productions copies a working list into a slice of exactly its length.
to_slice_productions :: proc(
	list: [dynamic]Production,
	allocator := context.allocator,
) -> []Production {
	sliced := make([]Production, len(list), allocator)
	copy(sliced, list[:])
	return sliced
}

// to_slice_rules copies a working list into a slice of exactly its length. The rules
// are held by value, so the copy shares every list and source view with the original
// and neither of them frees them.
to_slice_rules :: proc(list: [dynamic]Rule, allocator := context.allocator) -> []Rule {
	sliced := make([]Rule, len(list), allocator)
	copy(sliced, list[:])
	return sliced
}

// destroy_file frees all allocations owned by file, with the allocator the parser
// built it with.
destroy_file :: proc(file: ^File) {
	for decl in file.decls {
		destroy_decl(decl, file.allocator)
	}
	delete(file.decls, file.allocator)
}

destroy_decl :: proc(decl: Decl, allocator: mem.Allocator = context.allocator) {
	switch v in decl {
	case Rule:
		delete(v.params, allocator)
		if v.production != nil do destroy_production(v.production, allocator)
	case Binding:
		destroy_production(v.directive, allocator)
	case Comment_Group:
		delete(v.list, allocator)
	}
}

// branch_count returns the number of branches a chain of choices holds. The chain
// leans left, so counting is walking the left spine down and adding the right side at
// each step.
branch_count :: proc(alternative: ^Alternative) -> int {
	inner, is_chain := alternative.lhs.(^Alternative)
	return (is_chain ? branch_count(inner) : 1) + 1
}

// collect_branches returns the branches of an alternative as a flat list. The chain
// of choices leans left, so the branches are read by walking the left spine down and
// taking the right side at each step.
//
// It only reads: the chain and its branches still belong to the caller, which frees
// them with destroy_production. A caller that owns the alternative instead frees just
// the chain nodes with destroy_alternative_chain, once the branches are held.
collect_branches :: proc(
	alternative: ^Alternative,
	allocator := context.allocator,
) -> []Production {
	branches := make([]Production, branch_count(alternative), allocator)
	collect_branches_into(alternative, branches[:])
	return branches
}

// collect_branches_into writes the branches of a chain into the front of branches and
// returns the rest of it, so that a link further left writes before this one. The
// list must be as long as branch_count reports.
collect_branches_into :: proc(alternative: ^Alternative, branches: []Production) -> []Production {
	// The left side is either a further link of the chain or a branch.
	inner, is_chain := alternative.lhs.(^Alternative)
	rest := branches
	if is_chain {
		rest = collect_branches_into(inner, branches)
	} else {
		rest[0] = alternative.lhs
		rest = rest[1:]
	}
	rest[0] = alternative.rhs
	return rest[1:]
}

// destroy_alternative_chain frees the nodes of a chain of choices and nothing else: the
// branches they held are not freed, since whoever collected them out owns them now.
destroy_alternative_chain :: proc(
	alternative: ^Alternative,
	allocator := context.allocator,
) {
	inner, is_chain := alternative.lhs.(^Alternative)
	if is_chain do destroy_alternative_chain(inner, allocator)
	free(alternative, allocator)
}

// destroy_production frees everything a production owns, with allocator. A leaf owns
// nothing; the rest own the nodes and lists they hold.
destroy_production :: proc(production: Production, allocator: mem.Allocator = context.allocator) {
	switch v in production {
	case Ident, String_Lit, Regex_Lit, External_Value:
	case Sequence:
		for e in v.productions {
			destroy_production(e, allocator)
		}
		delete(v.productions, allocator)
	case ^Alternative:
		destroy_production(v.lhs, allocator)
		destroy_production(v.rhs, allocator)
		free(v, allocator)
	case ^Optional:
		destroy_production(v.production, allocator)
		free(v, allocator)
	case ^Repetition:
		destroy_production(v.production, allocator)
		free(v, allocator)
	case ^Group:
		destroy_production(v.production, allocator)
		free(v, allocator)
	case Qual_Ident:
	case ^Call:
		for e in v.args {
			destroy_production(e, allocator)
		}
		delete(v.args, allocator)
		free(v, allocator)
	case Directive:
		for e in v.args {
			destroy_production(e, allocator)
		}
		delete(v.args, allocator)
	case ^Tagged_Production:
		destroy_production(v.production, allocator)
		delete(v.tag, allocator)
		free(v, allocator)
	}
}

// Decl_Index_At returns the index of the declaration that covers offset, and ok is
// false when the offset falls outside every declaration, which is past the end of
// the file or inside the run of whitespace between two of them.
//
// Declarations are in source order and none spans another, so the one that covers
// an offset is the last one that starts at or before it. A position in a blank line
// between two declarations therefore belongs to the one before it.
Decl_Index_At :: proc(file: ^File, offset: int) -> (index: int, ok: bool) {
	found := -1
	for d, i in file.decls {
		if decl_pos(d) > offset do break
		found = i
	}
	return found, found >= 0
}
