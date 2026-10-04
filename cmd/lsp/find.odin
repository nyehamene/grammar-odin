package lsp

import "../../ast"

// Hit_Kind describes what kind of token sat at the requested offset.
Hit_Kind :: enum {
	None,
	Ident, // a plain identifier reference in a rule body
	Call_Name, // the name of a rule invocation, e.g. `<greet ...>`
	Param, // a rule parameter
	Rule_Name, // the name of a rule declaration
	Binding_Name, // the name of an import binding declaration
	Member_Object, // the receiver of a member access, e.g. the `base` in `base.expr`
	Member, // the member of a member access, e.g. the `expr` in `base.expr`
	Directive, // a directive name, e.g. `@import`
	String, // a string literal
	Regex, // a regular expression literal
	External, // an external value
}

// Hit is the outcome of a source-offset lookup into a parsed file.
Hit :: struct {
	kind:          Hit_Kind,
	ident:         ast.Ident,
	literal:       string,
	member_object: string, // receiver name when kind == .Member
	decl:          int, // decl index in Loaded_File.file when kind == .Param
}

// find_hit locates the most specific node in file whose source span contains
// offset. Offsets between tokens (whitespace, `=`, quotes) usually miss.
find_hit :: proc(file: ^ast.File, offset: int) -> Hit {
	for decl, id in file.decls {
		#partial switch d in decl {
		case ast.Rule:
			if hit_ident(d.ident, offset) {
				return Hit{kind = .Rule_Name, ident = d.ident}
			}

			params := make(map[string]bool, len(d.params))
			defer delete(params)

			for p in d.params {
				if hit_ident(p, offset) {
					return Hit{kind = .Param, ident = p, decl = id}
				}
				params[p.name] = true
			}
			if h := find_hit_expr(d.expr, offset); found(h) {
				if h.ident.name in params {
					h.kind = .Param
					h.decl = id
				}
				return h
			}
		case ast.Binding:
			if hit_ident(d.ident, offset) {
				return Hit{kind = .Binding_Name, ident = d.ident}
			}
			if h := find_hit_expr(d.directive, offset); found(h) {
				return h
			}
		case ast.Comment_Group:
		}
	}
	return Hit{kind = .None}
}

// find_hit_expr searches a single expression (and all sub-expressions) for an
// offset. Productions are traversed outermost-first so the most specific token
// wins.
find_hit_expr :: proc(expr: ast.Production, offset: int) -> Hit {
	#partial switch v in expr {
	case ast.Ident:
		if hit_ident(v, offset) {
			return Hit{kind = .Ident, ident = v}
		}
	case ast.Qual_Ident:
		if hit_ident(v.lhs, offset) {
			return Hit{kind = .Member_Object, ident = v.lhs}
		}
		if hit_ident(v.rhs, offset) {
			hit := Hit {
				kind  = .Member,
				ident = v.rhs,
			}
			hit.member_object = v.lhs.name
			return hit
		}
	case ^ast.Call:
		h: Hit
		switch it in v.ident {
		case ast.Ident:
			h = find_hit_expr(it, offset)
		case ast.Qual_Ident:
			h = find_hit_expr(it, offset)
		}
		if h.kind != .None {
			h.kind = .Call_Name
			return h
		}
		for arg in v.args {
			if h := find_hit_expr(arg, offset); found(h) {
				return h
			}
		}
	case ast.Directive:
		if hit_ident(v.ident, offset) {
			return Hit{kind = .Directive, ident = v.ident}
		}
		for arg in v.args {
			if h := find_hit_expr(arg, offset); found(h) {
				return h
			}
		}
	case ast.Sequence:
		for e in v.exprs {
			if h := find_hit_expr(e, offset); found(h) {
				return h
			}
		}
	case ast.Alternative:
		for e in v.exprs {
			if h := find_hit_expr(e, offset); found(h) {
				return h
			}
		}
	case ast.Optional:
		for e in v.exprs {
			if h := find_hit_expr(e, offset); found(h) {
				return h
			}
		}
	case ast.Repetition:
		for e in v.exprs {
			if h := find_hit_expr(e, offset); found(h) {
				return h
			}
		}
	case ast.Group:
		for e in v.exprs {
			if h := find_hit_expr(e, offset); found(h) {
				return h
			}
		}
	case ast.String_Lit:
		if offset >= v.pos && offset < v.pos + len(v.value) {
			return Hit{kind = .String, literal = v.value}
		}
	case ast.Regex_Lit:
		if offset >= v.pos && offset < v.pos + len(v.value) {
			return Hit{kind = .Regex, literal = v.value}
		}
	case ast.External_Value:
		if offset >= v.pos && offset < v.pos + len(v.name) {
			return Hit{kind = .External, literal = v.name}
		}
	case ast.Tagged_Production:
		// A tag annotates the production it follows, so the annotation itself
		// names nothing: look inside it.
		return find_hit_expr(v.expr^, offset)
	}
	return Hit{kind = .None}
}

hit_ident :: proc(i: ast.Ident, offset: int) -> bool {
	return offset >= i.pos && offset < i.pos + len(i.name)
}

found :: proc(h: Hit) -> bool {
	return h.kind != .None
}
