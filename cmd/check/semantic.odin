package check

import "core:fmt"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:sort"
import "core:strings"

import "../../ast"
import "../../token"

// Type is the type of a declaration or expression as resolved by the checker.
Type :: enum {
	Unknown,
	String, // a string literal, e.g. "foo"
	Regexp, // a regular expression literal, e.g. '[a-z]+'
	External, // an external value, e.g. $name
	Production, // a rule (a named production) without any parameter
	Proc, // a rule (a named production) with one or more parameter
	Namespace, // an imported namespace, bound by @import
}

Operand_Kind :: enum {
	Invalid,
	LValue,
	RValue,
	Namespace,
}

Operand :: struct {
	kind:  Operand_Kind,
	type:  Type,
	pos:   int,
	name:  string,
	arity: int, // number of parameters a Proc expects; meaningful for .Proc
}

Operand_invalid :: proc(o: ^Operand, pos: int, name := "") {
	o.kind = .Invalid
	o.type = .Unknown
	o.pos = pos
	o.name = name
}

Operand_lvalue :: proc(o: ^Operand, type: Type, pos: int, name := "") {
	o.kind = .LValue
	o.type = type
	o.pos = pos
	o.name = name
}

Operand_rvalue :: proc(o: ^Operand, type: Type, pos: int, name := "") {
	o.kind = .RValue
	o.type = type
	o.pos = pos
	o.name = name
}

Operand_ns :: proc(o: ^Operand, pos: int, name := "") {
	o.kind = .Namespace
	o.type = .Namespace
	o.pos = pos
	o.name = name
}

// Severity classifies how urgent a diagnostic is. Only errors make `grammar
// check` exit non-zero; a warning is advisory and never changes the exit
// status.
Severity :: enum {
	Error,
	Warning,
}

// Semantic_Error is a single diagnostic reported by the checker.
Semantic_Error :: struct {
	path:     string, // display path, owned
	offset:   int, // source offset of the diagnostic
	line:     int,
	col:      int,
	severity: Severity,
	message:  string, // owned
}

// Rule_Ref identifies the first declaration of a rule in a namespace.
Rule_Ref :: struct {
	type:       Type,
	arity:      int,
	file:       ^Loaded_File, // the file declaring the rule
	offset:     int, // source offset of the rule name
	decl_index: int,
}

// Use_Counts tallies the references made to one declared name. self counts the
// references made by the declaration's own rule body, because a rule that
// references nothing but itself is still unused: reachability is judged by
// whether some *other* rule names it.
Use_Counts :: struct {
	total: int,
	self:  int,
}

// used_by_other reports whether some rule other than referrer named this
// declaration.
used_by_other :: proc(counts: Use_Counts, referrer: string) -> bool {
	return counts.total > counts.self
}

// record_use notes one reference to name made from the rule body referrer.
record_use :: proc(uses: ^map[string]Use_Counts, name, referrer: string) {
	counts := uses[name]
	counts.total += 1
	if referrer == name do counts.self += 1
	uses[name] = counts
}

// Namespace is the collection of rules declared in a directory. Every grammar
// file in the same directory contributes its rules to the same namespace.
Namespace :: struct {
	rules:     map[string]Rule_Ref,
	rule_uses: map[string]Use_Counts, // rule name -> references to it
}

// Loaded_File is a grammar file loaded into the compilation unit.
Loaded_File :: struct {
	display:         string, // path used in messages, owned
	src:             string, // source text (view into raw)
	raw:             []byte, // source bytes, owned
	file:            ast.File,
	namespace_path:  string, // absolute path of the containing directory, owned
	bindings:        map[string]string, // binding name -> absolute directory of the imported namespace
	private_rules:   map[string]Rule_Ref,
	private_uses:    map[string]Use_Counts, // private rule name -> references to it
	used_bindings:   map[string]bool, // binding name -> referenced in this file
	binding_offsets: map[string]int, // binding name -> offset of the binding's name
	enclosing_rule:  string, // name of the rule whose body is being walked
	broken:          bool, // file had lexical or syntax errors
}

// Compilation_Unit maps loaded files and namespaces and collects diagnostics.
Compilation_Unit :: struct {
	files:       map[string]^Loaded_File,
	files_order: [dynamic]^Loaded_File, // deterministic insertion order
	namespaces:  map[string]^Namespace,
	loading_ns:  map[string]bool, // absolute directories currently being loaded
	errors:      [dynamic]Semantic_Error,
	cwd:         string,
}

// new_compilation_unit creates an empty compilation unit rooted at the current
// working directory.
new_compilation_unit :: proc(allocator := context.allocator) -> Compilation_Unit {
	cu: Compilation_Unit
	cwd, err := os.get_working_directory(allocator)
	if err != nil || cwd == "" {
		cwd = strings.clone(".", allocator)
	}
	cu.cwd = cwd
	return cu
}

// destroy_compilation_unit frees all memory owned by cu.
destroy_compilation_unit :: proc(cu: ^Compilation_Unit) {
	for _, f in cu.files {
		ast.destroy_file(&f.file)
		delete(f.raw)
		delete(f.display)
		delete(f.namespace_path)
		for _, dir in f.bindings {
			delete(dir)
		}
		delete(f.bindings)
		delete(f.private_rules)
		delete(f.private_uses)
		delete(f.used_bindings)
		delete(f.binding_offsets)
		free(f)
	}
	// cu.files map keys are owned absolute paths.
	for key in cu.files {
		delete(key)
	}
	delete(cu.files)
	for path, _ in cu.loading_ns {
		delete(path)
	}
	delete(cu.loading_ns)
	for _, ns in cu.namespaces {
		delete(ns.rules)
		delete(ns.rule_uses)
		free(ns)
	}
	for path, _ in cu.namespaces {
		delete(path)
	}
	delete(cu.namespaces)
	for e in cu.errors {
		delete(e.path)
		delete(e.message)
	}
	delete(cu.errors)
	delete(cu.files_order)
	delete(cu.cwd)
}

// check loads path (or, for a directory, every grammar file in it) along with
// all imported namespaces into a compilation unit, resolves names and checks
// types, then reports every diagnostic to stderr. Warnings are printed with a
// `warning: ` prefix and do not affect the exit status, which is non-zero only
// when at least one error was found.
check :: proc(path: string, mode: Mode, stderr: io.Writer) -> int {
	cu := new_compilation_unit()
	defer destroy_compilation_unit(&cu)

	if mode == .File || !os.is_directory(path) {
		load(&cu, path)
	} else {
		abs := abs_path(&cu, path)
		load_namespace(&cu, abs)
		delete(abs)
	}

	run_checks(&cu)

	sort.quick_sort_proc(cu.errors[:], cmp_errors)

	for e in cu.errors {
		if e.severity == .Warning {
			io.write_string(
				stderr,
				fmt.tprintf("%s:%d:%d: warning: %s\n", e.path, e.line, e.col, e.message),
			)
			continue
		}
		io.write_string(stderr, fmt.tprintf("%s:%d:%d: %s\n", e.path, e.line, e.col, e.message))
	}

	if has_errors(&cu) {
		return 1
	}
	return 0
}

// load parses path (a relative or absolute file path) and transitively loads
// every namespace it imports. Already-loaded files are returned from cache.
load :: proc(cu: ^Compilation_Unit, path: string) -> ^Loaded_File {
	abs := abs_path(cu, path)
	if f, ok := cu.files[abs]; ok {
		delete(abs)
		return f
	}

	display := display_of(cu, abs)
	data, ferr := os.read_entire_file(abs, context.allocator)
	if ferr != nil {
		add_error(cu, display, "", 0, fmt.tprintf("could not read file '%s'", display))
		delete(display)
		delete(abs)
		return nil
	}

	src := string(data)
	tokens, lex_errors := token.scan(src)
	file, parse_errors := ast.parse_file(src, tokens[:])
	delete(tokens)

	fi := new(Loaded_File)
	fi.display = display
	fi.src = src
	fi.raw = data
	fi.file = file
	fi.namespace_path = strings.clone(filepath.dir(abs))
	fi.bindings = make(map[string]string)
	fi.private_rules = make(map[string]Rule_Ref)
	fi.private_uses = make(map[string]Use_Counts)
	fi.used_bindings = make(map[string]bool)
	fi.binding_offsets = make(map[string]int)

	for e in lex_errors {
		add_error(cu, fi.display, fi.src, e.offset, e.message)
		fi.broken = true
	}
	for e in parse_errors {
		add_error(cu, fi.display, fi.src, e.offset, e.message)
		fi.broken = true
	}
	delete(lex_errors)
	delete(parse_errors)

	cu.files[abs] = fi
	append(&cu.files_order, fi)

	resolve_imports(cu, fi)
	return fi
}

// resolve_imports loads the namespace of every @import binding in fi and
// records the bindings in file scope.
resolve_imports :: proc(cu: ^Compilation_Unit, fi: ^Loaded_File) {
	for decl in fi.file.decls {
		#partial switch d in decl {
		case ast.Binding_Decl:
			import_path := unquote(d.path.value)
			resolved, rerr := filepath.join([]string{fi.namespace_path, import_path})
			cleaned, _ := filepath.clean(resolved)
			delete(resolved)
			if rerr != nil {
				add_error(
					cu,
					fi.display,
					fi.src,
					d.path.pos,
					fmt.tprintf("invalid import path '%s'", import_path),
				)
				continue
			}

			if cu.loading_ns[cleaned] {
				cycle_display := display_of(cu, cleaned)
				add_error(
					cu,
					fi.display,
					fi.src,
					d.pos,
					fmt.tprintf("import cycle detected involving %s", cycle_display),
				)
				delete(cycle_display)
				delete(cleaned)
				continue
			}

			if !os.is_directory(cleaned) {
				add_error(
					cu,
					fi.display,
					fi.src,
					d.path.pos,
					fmt.tprintf("namespace \"%s\" does not exist", import_path),
				)
				delete(cleaned)
				continue
			}

			load_namespace(cu, cleaned)
			fi.bindings[d.name.name] = cleaned
			fi.binding_offsets[d.name.name] = d.name.pos
		}
	}
}

// load_namespace loads every .grammar file in dir into the compilation unit.
load_namespace :: proc(cu: ^Compilation_Unit, dir: string) {
	if _, ok := cu.namespaces[dir]; ok do return
	if cu.loading_ns[dir] do return

	key := strings.clone(dir)
	defer delete(key)
	cu.loading_ns[key] = true
	files := list_grammar_files(dir)
	for f in files {
		load(cu, f)
		delete(f)
	}
	delete(files)
	delete_key(&cu.loading_ns, key)
}

// list_grammar_files returns clones of the absolute paths of the .grammar
// files directly inside dir. The strings belong to the caller.
list_grammar_files :: proc(dir: string) -> [dynamic]string {
	files := make([dynamic]string)
	w := os.walker_create_path(dir)
	defer os.walker_destroy(&w)
	for {
		info, ok := os.walker_walk(&w)
		if !ok do break
		if info.type == .Regular && strings.has_suffix(info.fullpath, ".grammar") {
			append(&files, strings.clone(info.fullpath))
		}
	}
	return files
}

// bind_all registers every rule in its file's namespace and reports duplicate
// declarations. Names that collide within a single file (a rule and a binding,
// or two bindings) are reported as well. Private rules (`_name`) are registered
// in the declaring file instead of the namespace, so they never collide across
// files.
bind_all :: proc(cu: ^Compilation_Unit) {
	for i in 0 ..< len(cu.files_order) {
		fi := cu.files_order[i]
		ns := get_namespace(cu, fi.namespace_path)
		seen := make(map[string]int)
		defer delete(seen)

		for decl in fi.file.decls {
			#partial switch d in decl {
			case ast.Rule_Decl:
				if is_malformed_private_name(d.name.name) {
					add_error(
						cu,
						fi.display,
						fi.src,
						d.name.pos,
						fmt.tprintf(
							"malformed private rule name %s. a private rule name is an underscore followed by a letter, as in _helper",
							d.name.name,
						),
					)
				}
				if other, ok := seen[d.name.name]; ok {
					add_redeclared(cu, fi, d.name.pos, d.name.name, fi, other)
				} else if other_ref, exists := ns.rules[d.name.name]; exists {
					add_redeclared(
						cu,
						fi,
						d.name.pos,
						d.name.name,
						other_ref.file,
						other_ref.offset,
					)
				} else {
					seen[d.name.name] = d.name.pos

					arity := len(d.params)
					rule := Rule_Ref {
						file   = fi,
						offset = d.name.pos,
						type   = .Production,
						arity  = arity,
					}
					if arity > 0 {
						rule.type = .Proc
					}

					if is_private_rule(d.name.name) {
						fi.private_rules[d.name.name] = rule
					} else {
						ns.rules[d.name.name] = rule
					}
				}
			case ast.Binding_Decl:
				if other, ok := seen[d.name.name]; ok {
					add_redeclared(cu, fi, d.name.pos, d.name.name, fi, other)
				} else {
					seen[d.name.name] = d.name.pos
				}
			}
		}
	}
}

// get_namespace returns the namespace for dir, creating it on first use.
get_namespace :: proc(cu: ^Compilation_Unit, dir: string) -> ^Namespace {
	if ns, ok := cu.namespaces[dir]; ok do return ns
	ns := new(Namespace)
	ns.rules = make(map[string]Rule_Ref)
	ns.rule_uses = make(map[string]Use_Counts)
	cu.namespaces[strings.clone(dir)] = ns
	return ns
}

// check_file performs expression analysis on every rule body in fi. The per-file
// use sets are cleared first: the server re-runs this on every keystroke, and
// `check` may run the phase more than once over a unit.
check_file :: proc(cu: ^Compilation_Unit, fi: ^Loaded_File) {
	if fi.broken do return
	clear(&fi.private_uses)
	clear(&fi.used_bindings)
	for decl in fi.file.decls {
		#partial switch d in decl {
		case ast.Rule_Decl:
			// Record which rule is being walked so that a reference can tell
			// whether it came from the declaring rule itself.
			fi.enclosing_rule = d.name.name
			for body in d.body {
				check_body(cu, fi, d.params[:], body)
			}
			fi.enclosing_rule = ""
			if len(d.params) > 0 {
				check_unused_params(cu, fi, d.params[:], d.body[:])
			}
		}
	}
	check_unused_private_rules(cu, fi)
	check_unused_bindings(cu, fi)
}

// check_unused_private_rules warns about every private rule of fi that no other
// rule in the same file references. A declaration that was rejected as a
// redeclaration is not registered, and is already reported as an error, so it is
// skipped here. The declarations are walked in source order so the warnings come
// out deterministically.
check_unused_private_rules :: proc(cu: ^Compilation_Unit, fi: ^Loaded_File) {
	for decl in fi.file.decls {
		#partial switch d in decl {
		case ast.Rule_Decl:
			if !is_private_rule(d.name.name) do continue
			// A declaration that lost a redeclaration contest was never
			// registered; the one that won was, and its offset tells them apart.
			if ref, ok := fi.private_rules[d.name.name]; !ok || ref.offset != d.name.pos {
				continue
			}
			if used_by_other(fi.private_uses[d.name.name], d.name.name) do continue
			add_warning(
				cu,
				fi.display,
				fi.src,
				d.name.pos,
				fmt.tprintf("unused private rule: %s", d.name.name),
			)
		}
	}
}

// check_unused_bindings warns about every import binding of fi that no rule
// body references. A binding whose import failed is skipped: it is already an
// error, and it was never registered, so nothing could have referenced it.
check_unused_bindings :: proc(cu: ^Compilation_Unit, fi: ^Loaded_File) {
	for decl in fi.file.decls {
		#partial switch d in decl {
		case ast.Binding_Decl:
			if _, ok := fi.bindings[d.name.name]; !ok do continue
			if fi.used_bindings[d.name.name] do continue
			add_warning(
				cu,
				fi.display,
				fi.src,
				d.name.pos,
				fmt.tprintf("unused binding: %s", d.name.name),
			)
		}
	}
}

// check_unused_local_rules warns about every local rule of every loaded file
// that no other rule in its namespace references. Exported rules are never
// reported: an importing namespace may reference one that nothing inside its own
// namespace does.
//
// Local rules are counted per namespace rather than per file, so this runs once
// over the whole unit after every file body has been walked.
check_unused_local_rules :: proc(cu: ^Compilation_Unit) {
	for i in 0 ..< len(cu.files_order) {
		fi := cu.files_order[i]
		if fi.broken do continue
		ns := cu.namespaces[fi.namespace_path]
		if ns == nil do continue

		for decl in fi.file.decls {
			#partial switch d in decl {
			case ast.Rule_Decl:
				if !is_local_rule(d.name.name) do continue
				// As with private rules, only the declaration that was actually
				// registered can be reported; Rule_Ref.offset says which it was.
				if ref, ok := ns.rules[d.name.name]; !ok || ref.offset != d.name.pos {
					continue
				}
				if used_by_other(ns.rule_uses[d.name.name], d.name.name) do continue
				add_warning(
					cu,
					fi.display,
					fi.src,
					d.name.pos,
					fmt.tprintf("unused local rule: %s", d.name.name),
				)
			}
		}
	}
}

// check_unused_params reports every proc parameter that is never referenced in
// the rule body.
check_unused_params :: proc(cu: ^Compilation_Unit, fi: ^Loaded_File, params: []ast.Ident, body: []ast.Expr) {
	for p in params {
		used := false
		for b in body {
			if uses_param(b, p.name) {
				used = true
				break
			}
		}
		if !used {
			add_error(
				cu,
				fi.display,
				fi.src,
				p.pos,
				fmt.tprintf("unused proc parameter: %s", p.name),
			)
		}
	}
}

// uses_param reports whether param appears as an identifier anywhere in expr.
uses_param :: proc(expr: ast.Expr, param: string) -> bool {
	switch v in expr {
	case ast.Ident:
		return v.name == param
	case ast.String_Lit, ast.Regex_Lit, ast.External_Value, ast.Directive_Expr:
		return false
	case ast.Term_Expr:
		return uses_param(v.x^, param)
	case ast.Member_Expr:
		return uses_param(v.object^, param) || uses_param(v.member, param)
	case ^ast.Call_Expr:
		return uses_param(v.name, param) || exprs_use_param(v.args[:], param)
	case ast.Sequence_Expr:
		return exprs_use_param(v.exprs[:], param)
	case ast.Alternative_Expr:
		return exprs_use_param(v.exprs[:], param)
	case ast.Optional_Expr:
		return exprs_use_param(v.exprs[:], param)
	case ast.Repetition_Expr:
		return exprs_use_param(v.exprs[:], param)
	case ast.Group_Expr:
		return exprs_use_param(v.exprs[:], param)
	case ast.Tagged_Expr:
		return uses_param(v.expr^, param)
	}
	return false
}

exprs_use_param :: proc(exprs: []ast.Expr, param: string) -> bool {
	for e in exprs {
		if uses_param(e, param) do return true
	}
	return false
}

// check_body checks expr with a rule's parameters in scope.
check_body :: proc(cu: ^Compilation_Unit, fi: ^Loaded_File, params: []ast.Ident, expr: ast.Expr) {
	o: Operand
	check_expr_scoped(cu, fi, params, expr, &o)
}

// is_param reports whether expr is one of the given parameters.
is_param :: proc(params: []ast.Ident, expr: ast.Expr) -> bool {
	ident, ok := expr.(ast.Ident)
	if !ok do return false
	for p in params {
		if p.name == ident.name do return true
	}
	return false
}

// check_expr_scoped is check_expr with a parameter list in scope.
check_expr_scoped :: proc(
	cu: ^Compilation_Unit,
	fi: ^Loaded_File,
	params: []ast.Ident,
	expr: ast.Expr,
	o: ^Operand,
) {

	switch v in expr {
	case ast.Ident:
		if is_param(params, v) {
			Operand_rvalue(o, .Production, v.pos, v.name)
			break
		}
		// A parameter shadows a rule or binding of the same name, so the tests
		// below only see references that really are rule or binding uses.
		if is_binding(fi, v.name) {
			mark_binding_used(fi, v.name)
			Operand_ns(o, v.pos, v.name)
			break
		}

		rule, defined := resolve_rule(cu, fi, v.name)
		if !defined {
			Operand_invalid(o, v.pos, v.name)
			add_error(
				cu,
				fi.display,
				fi.src,
				v.pos,
				fmt.tprintf("undefined identifier: %s", v.name),
			)
			break
		}
		mark_rule_used(cu, fi, v.name)
		Operand_lvalue(o, rule.type, v.pos, v.name)
		o.arity = rule.arity

	case ast.Term_Expr:
		check_expr_scoped(cu, fi, params, v.x^, o)
		if o.kind == .LValue {
			if o.type == .Proc {
				add_error(
					cu,
					fi.display,
					fi.src,
					o.pos,
					fmt.tprintf("proc cannot be used as a production: %s", o.name),
				)
			}
			break
		}
		switch o.type {
		case .Unknown, .String, .Regexp, .External, .Production:
		case .Namespace:
			add_error(
				cu,
				fi.display,
				fi.src,
				o.pos,
				fmt.tprintf("namespace cannot be used as an production: %s", o.name),
			)
		case .Proc:
			add_error(
				cu,
				fi.display,
				fi.src,
				o.pos,
				fmt.tprintf("proc cannot be used as a production: %s", o.name),
			)
		}

	case ast.Member_Expr:
		check_member(cu, fi, v, o)

	case ^ast.Call_Expr:
		name_op: Operand
		check_expr_scoped(cu, fi, params, v.name, &name_op)
		if name_op.kind == .Invalid {
			Operand_invalid(o, v.pos, name_op.name)
			break
		}
		if name_op.type != .Proc || name_op.kind == .RValue {
			Operand_invalid(o, v.pos, name_op.name)
			add_error(
				cu,
				fi.display,
				fi.src,
				name_op.pos,
				fmt.tprintf("not callable: '%s'", name_op.name),
			)
		}

		if name_op.type == .Proc && name_op.kind == .LValue && len(v.args) != name_op.arity {
			plural := "s" if name_op.arity != 1 else ""
			add_error(
				cu,
				fi.display,
				fi.src,
				name_op.pos,
				fmt.tprintf(
					"proc '%s' expects %d argument%s, but got %d",
					name_op.name,
					name_op.arity,
					plural,
					len(v.args),
				),
			)
		}

		Operand_lvalue(o, .Production, v.pos, name_op.name)

		for arg in v.args {
			arg_op: Operand
			check_expr_scoped(cu, fi, params, arg, &arg_op)
			if arg_op.kind == .LValue && arg_op.type != .Proc {
				continue
			}

			switch arg_op.type {
			case .Unknown, .String, .Regexp, .Production:
			case .External:
				add_error(
					cu,
					fi.display,
					fi.src,
					arg_op.pos,
					fmt.tprintf("external cannot be pass as proc argument: %s", arg_op.name),
				)
			case .Proc:
				add_error(
					cu,
					fi.display,
					fi.src,
					arg_op.pos,
					fmt.tprintf(
						"proc cannot be pass as argument to another proc: %s",
						arg_op.name,
					),
				)
			case .Namespace:
				add_error(
					cu,
					fi.display,
					fi.src,
					arg_op.pos,
					fmt.tprintf("namespace cannot be pass as proc argument: %s", arg_op.name),
				)
			}
		}

	case ast.Sequence_Expr:
		check_expr_group(cu, fi, params, v.pos, v.exprs[:], o)

	case ast.Alternative_Expr:
		check_expr_group(cu, fi, params, v.pos, v.exprs[:], o)

	case ast.Optional_Expr:
		check_expr_group(cu, fi, params, v.pos, v.exprs[:], o)

	case ast.Repetition_Expr:
		check_expr_group(cu, fi, params, v.pos, v.exprs[:], o)

	case ast.Group_Expr:
		check_expr_group(cu, fi, params, v.pos, v.exprs[:], o)

	case ast.Tagged_Expr:
		// A tag annotates the production it follows, so it is checked, and
		// yields an operand, exactly as the untagged production would.
		check_expr_scoped(cu, fi, params, v.expr^, o)

	case ast.String_Lit:
		Operand_lvalue(o, .String, v.pos, v.value)

	case ast.Regex_Lit:
		Operand_lvalue(o, .Regexp, v.pos, v.value)

	case ast.External_Value:
		Operand_rvalue(o, .External, v.pos, v.name)

	case ast.Directive_Expr:
		// Operand_rvalue(o, .Unknown, v.pos, v.name.name)
		Operand_invalid(o, v.pos, v.name.name)
	}
}

check_expr_group :: proc(
	cu: ^Compilation_Unit,
	fi: ^Loaded_File,
	params: []ast.Ident,
	pos: int,
	exprs: []ast.Expr,
	o: ^Operand,
) {
	for e in exprs {
		eop: Operand
		check_expr_scoped(cu, fi, params, e, &eop)
		if eop.kind == .LValue && eop.type == .Proc {
			add_error(
				cu,
				fi.display,
				fi.src,
				eop.pos,
				fmt.tprintf("proc cannot be used as a production: %s", eop.name),
			)
		}
	}
	Operand_lvalue(o, .Production, pos)
}

// check_expr resolves names in expr and reports undefined references.
check_expr :: proc(cu: ^Compilation_Unit, fi: ^Loaded_File, expr: ast.Expr, o: ^Operand) {
	check_expr_scoped(cu, fi, nil, expr, o)
}

// check_member validates a member access `receiver.member`: the receiver must
// be a binding to a namespace and the member must be a rule in that namespace.
check_member :: proc(cu: ^Compilation_Unit, fi: ^Loaded_File, m: ast.Member_Expr, o: ^Operand) {
	obj_op: Operand
	check_expr(cu, fi, m.object^, &obj_op)
	if obj_op.kind != .Namespace {
		if obj_op.kind == .Invalid {
			add_error(cu, fi.display, fi.src, m.pos, "expected a namespace on the left of '.'")
			return
		}
		add_error(
			cu,
			fi.display,
			fi.src,
			m.member.pos,
			fmt.tprintf("expected a namespace, but '%s' is not a namespace", obj_op.name),
		)
		return
	}

	obj_name := obj_op.name

	if target_dir, found := fi.bindings[obj_name]; found {
		// The receiver names a binding whether or not the member resolves, so
		// the binding counts as used either way.
		mark_binding_used(fi, obj_name)
		ns := cu.namespaces[target_dir]
		if ns == nil do return
		if !is_exported_rule(m.member.name) {
			// Only an exported rule crosses a namespace boundary. A local or
			// private rule of the target namespace is present but unreachable,
			// which is a different mistake from naming a rule that is not there.
			add_error(
				cu,
				fi.display,
				fi.src,
				m.member.pos,
				fmt.tprintf(
					"%s.%s is not exported. only a rule whose name starts with an uppercase letter is accessible from another namespace",
					obj_name,
					m.member.name,
				),
			)
			return
		}
		if _, has := ns.rules[m.member.name]; !has {
			ns_name := filepath.base(target_dir)
			add_error(
				cu,
				fi.display,
				fi.src,
				m.member.pos,
				fmt.tprintf(
					"%s.%s is undefined. namespace %s has no field %s",
					obj_name,
					m.member.name,
					ns_name,
					m.member.name,
				),
			)
			return
		}
		// The member resolves in another namespace, which is not where the
		// referencing file's rules live, so mark the target namespace directly.
		mark_namespace_rule_used(ns, m.member.name)
		return
	}

}

is_binding :: proc(fi: ^Loaded_File, name: string) -> bool {
	if _, ok := fi.bindings[name]; ok {
		return true
	}
	return false
}

// mark_binding_used records that fi referenced the binding name. Bindings are
// declared outside any rule body, so there is no self-reference to discount and
// a plain flag is enough.
mark_binding_used :: proc(fi: ^Loaded_File, name: string) {
	fi.used_bindings[name] = true
}

// mark_rule_used records a reference to name made from the body of
// fi.enclosing_rule, routing it to the private or the namespace use set as
// appropriate. It is called only after the name resolves, so a failed lookup
// records nothing.
mark_rule_used :: proc(cu: ^Compilation_Unit, fi: ^Loaded_File, name: string) {
	if _, ok := fi.private_rules[name]; ok {
		record_use(&fi.private_uses, name, fi.enclosing_rule)
		return
	}
	if ns := cu.namespaces[fi.namespace_path]; ns != nil {
		record_use(&ns.rule_uses, name, fi.enclosing_rule)
	}
}

// mark_namespace_rule_used records a reference to a rule of ns made from another
// namespace, through an import. There is no enclosing rule on the other side of
// the boundary, so the reference cannot be a self-reference.
mark_namespace_rule_used :: proc(ns: ^Namespace, name: string) {
	record_use(&ns.rule_uses, name, "")
}

resolve_rule :: proc(cu: ^Compilation_Unit, fi: ^Loaded_File, name: string) -> (Rule_Ref, bool) {
	if priv_rule, ok := fi.private_rules[name]; ok {
		return priv_rule, true
	}
	ns := cu.namespaces[fi.namespace_path]
	if ns == nil do return {}, false
	rule, ok := ns.rules[name]
	return rule, ok
}

// add_redeclared reports that name is declared twice, pointing at the first
// declaration.
add_redeclared :: proc(
	cu: ^Compilation_Unit,
	fi: ^Loaded_File,
	offset: int,
	name: string,
	other_file: ^Loaded_File,
	other_offset: int,
) {
	other_pos := token.position_at(other_file.src, other_offset)
	add_error(
		cu,
		fi.display,
		fi.src,
		offset,
		fmt.tprintf(
			"field %s redeclared in this namespace. (see other declaration at %s:%d:%d)",
			name,
			other_file.display,
			other_pos.line,
			other_pos.column,
		),
	)
}

// cmp_errors orders two diagnostics by path, line, then column.
cmp_errors :: proc(a, b: Semantic_Error) -> int {
	if a.path != b.path {
		return -1 if a.path < b.path else 1
	}
	if a.line != b.line {
		return -1 if a.line < b.line else 1
	}
	if a.col != b.col {
		return -1 if a.col < b.col else 1
	}
	if a.message != b.message {
		return -1 if a.message < b.message else 1
	}
	return 0
}

// add_error appends an error diagnostic located at offset within src. The path
// and the message are cloned onto the heap so the unit can free them.
add_error :: proc(
	cu: ^Compilation_Unit,
	display_path: string,
	src: string,
	offset: int,
	message: string,
) {
	add_diag(cu, .Error, display_path, src, offset, message)
}

// add_warning appends a warning diagnostic located at offset within src.
// Warnings are advisory: they are reported like errors but never make a check
// run fail.
add_warning :: proc(
	cu: ^Compilation_Unit,
	display_path: string,
	src: string,
	offset: int,
	message: string,
) {
	add_diag(cu, .Warning, display_path, src, offset, message)
}

// add_diag appends a diagnostic of the given severity located at offset within
// src.
add_diag :: proc(
	cu: ^Compilation_Unit,
	severity: Severity,
	display_path: string,
	src: string,
	offset: int,
	message: string,
) {
	line, col := 1, 1
	if src != "" {
		pos := token.position_at(src, offset)
		line, col = pos.line, pos.column
	}
	append(
		&cu.errors,
		Semantic_Error {
			path     = strings.clone(display_path),
			offset   = offset,
			line     = line,
			col      = col,
			severity = severity,
			message  = strings.clone(message),
		},
	)
}

// has_errors reports whether the unit holds at least one diagnostic of severity
// .Error.
has_errors :: proc(cu: ^Compilation_Unit) -> bool {
	for e in cu.errors {
		if e.severity == .Error do return true
	}
	return false
}

// abs_path returns the cleaned absolute form of path.
abs_path :: proc(cu: ^Compilation_Unit, path: string) -> string {
	if filepath.is_abs(path) {
		cleaned, _ := filepath.clean(path)
		return cleaned
	}
	joined, _ := filepath.join([]string{cu.cwd, path})
	cleaned, _ := filepath.clean(joined)
	delete(joined)
	return cleaned
}

// display_of returns a cwd-relative form of abs when possible.
display_of :: proc(cu: ^Compilation_Unit, abs: string) -> string {
	rel, err := filepath.rel(cu.cwd, abs)
	if err == nil && rel != "" && !filepath.is_abs(rel) {
		return rel
	}
	cleaned, _ := filepath.clean(abs)
	return cleaned
}

// unquote removes the surrounding double quotes from a string literal.
unquote :: proc(s: string) -> string {
	if len(s) >= 2 && s[0] == '"' && s[len(s) - 1] == '"' {
		return s[1:len(s) - 1]
	}
	return s
}

// is_exported_rule reports whether name declares an exported rule: a name
// starting with an uppercase letter. An exported rule is reachable from an
// importing namespace.
is_exported_rule :: proc(name: string) -> bool {
	if len(name) == 0 do return false
	return name[0] >= 'A' && name[0] <= 'Z'
}

// is_local_rule reports whether name declares a local rule: a name starting with
// a lowercase letter. A local rule is shared by every file of its namespace but
// is not exported, so it can only be named from inside that namespace.
is_local_rule :: proc(name: string) -> bool {
	if len(name) == 0 do return false
	return name[0] >= 'a' && name[0] <= 'z'
}

// is_private_rule reports whether name declares a private rule: an underscore
// followed by a letter, as in `_helper`. Such a rule is visible only inside the
// file that declares it.
is_private_rule :: proc(name: string) -> bool {
	if len(name) < 2 {
		return false
	}
	if name[0] != '_' || name[1] == '_' {
		return false
	}
	return is_alpha_byte(name[1])
}

// is_malformed_private_name reports whether name starts like a private rule name
// but is not one: a bare `_`, a name whose second character is not a letter, or
// a double-underscore name, which is reserved for `__extern__` values.
is_malformed_private_name :: proc(name: string) -> bool {
	if len(name) == 0 || name[0] != '_' {
		return false
	}
	return !is_private_rule(name)
}

is_alpha_byte :: proc(ch: byte) -> bool {
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
}
