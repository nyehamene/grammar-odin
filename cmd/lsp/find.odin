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
		case ast.Rule_Decl:
			if hit_ident(d.name, offset) {
				return Hit{kind = .Rule_Name, ident = d.name}
			}
			for p in d.params {
				if hit_ident(p, offset) {
					return Hit{kind = .Param, ident = p, decl = id}
				}
			}
			for e in d.body {
				if h := find_hit_expr(e, offset); found(h) {
					return h
				}
			}
		case ast.Binding_Decl:
			if hit_ident(d.name, offset) {
				return Hit{kind = .Binding_Name, ident = d.name}
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
// offset. Expressions are traversed outermost-first so the most specific token
// wins.
find_hit_expr :: proc(expr: ast.Expr, offset: int) -> Hit {
	#partial switch v in expr {
	case ast.Ident:
		if hit_ident(v, offset) {
			return Hit{kind = .Ident, ident = v}
		}
	case ast.Term_Expr:
		return find_hit_expr(v.x^, offset)
	case ast.Member_Expr:
		if obj, is_ident := v.object^.(ast.Ident); is_ident {
			if hit_ident(obj, offset) {
				return Hit{kind = .Member_Object, ident = obj}
			}
		} else if h := find_hit_expr(v.object^, offset); found(h) {
			return h
		}
		if hit_ident(v.member, offset) {
			hit := Hit {
				kind  = .Member,
				ident = v.member,
			}
			if obj, is_ident := v.object^.(ast.Ident); is_ident {
				hit.member_object = obj.name
			}
			return hit
		}
	case ^ast.Call_Expr:
		h := find_hit_expr(v.name, offset)
		if h.kind != .None {
			h.kind = .Call_Name
			return h
		}
		for arg in v.args {
			if h := find_hit_expr(arg, offset); found(h) {
				return h
			}
		}
	case ast.Directive_Expr:
		if hit_ident(v.name, offset) {
			return Hit{kind = .Directive, ident = v.name}
		}
		for arg in v.args {
			if h := find_hit_expr(arg, offset); found(h) {
				return h
			}
		}
	case ast.Sequence_Expr:
		for e in v.exprs {
			if h := find_hit_expr(e, offset); found(h) {
				return h
			}
		}
	case ast.Alternative_Expr:
		for e in v.exprs {
			if h := find_hit_expr(e, offset); found(h) {
				return h
			}
		}
	case ast.Optional_Expr:
		for e in v.exprs {
			if h := find_hit_expr(e, offset); found(h) {
				return h
			}
		}
	case ast.Repetition_Expr:
		for e in v.exprs {
			if h := find_hit_expr(e, offset); found(h) {
				return h
			}
		}
	case ast.Group_Expr:
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
	}
	return Hit{kind = .None}
}

hit_ident :: proc(i: ast.Ident, offset: int) -> bool {
	return offset >= i.pos && offset < i.pos + len(i.name)
}

found :: proc(h: Hit) -> bool {
	return h.kind != .None
}
