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
	String,     // a string literal, e.g. "foo"
	Regexp,     // a regular expression literal, e.g. '[a-z]+'
	External,   // an external value, e.g. $name
	Production, // a rule (a named production)
	Namespace,  // an imported namespace, bound by @import
}

// Semantic_Error is a single diagnostic reported by the checker.
Semantic_Error :: struct {
	path:    string, // display path, owned
	offset:  int,    // source offset of the diagnostic
	line:    int,
	col:     int,
	message: string, // owned
}

// Rule_Ref identifies the first declaration of a rule in a namespace.
Rule_Ref :: struct {
	file:   ^Loaded_File, // the file declaring the rule
	offset: int,          // source offset of the rule name
}

// Namespace is the collection of rules declared in a directory. Every grammar
// file in the same directory contributes its rules to the same namespace.
Namespace :: struct {
	rules: map[string]Rule_Ref,
}

// Loaded_File is a grammar file loaded into the compilation unit.
Loaded_File :: struct {
	display:         string, // path used in messages, owned
	src:             string, // source text (view into raw)
	raw:             []byte, // source bytes, owned
	file:            ast.File,
	namespace_path:  string, // absolute path of the containing directory, owned
	bindings:        map[string]string, // binding name -> absolute directory of the imported namespace
	binding_offsets: map[string]int,    // binding name -> offset of the binding's name
	broken:          bool,              // file had lexical or syntax errors
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
// types, then reports every diagnostic to stderr. It returns 0 when nothing
// was wrong and a non-zero value otherwise.
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

	bind_all(&cu)
	for i in 0 ..< len(cu.files_order) {
		check_file(&cu, cu.files_order[i])
	}

	sort.quick_sort_proc(cu.errors[:], cmp_errors)

	for e in cu.errors {
		io.write_string(stderr, fmt.tprintf("%s:%d:%d: %s\n", e.path, e.line, e.col, e.message))
	}

	if len(cu.errors) > 0 {
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
				add_error(cu, fi.display, fi.src, d.path.pos, fmt.tprintf("invalid import path '%s'", import_path))
				continue
			}

			if cu.loading_ns[cleaned] {
				cycle_display := display_of(cu, cleaned)
				add_error(cu, fi.display, fi.src, d.pos, fmt.tprintf("import cycle detected involving %s", cycle_display))
				delete(cycle_display)
				delete(cleaned)
				continue
			}

			if !os.is_directory(cleaned) {
				add_error(cu, fi.display, fi.src, d.path.pos, fmt.tprintf("namespace \"%s\" does not exist", import_path))
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

	cu.loading_ns[strings.clone(dir)] = true
	files := list_grammar_files(dir)
	for f in files {
		load(cu, f)
		delete(f)
	}
	delete(files)
	delete_key(&cu.loading_ns, dir)
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
// or two bindings) are reported as well.
bind_all :: proc(cu: ^Compilation_Unit) {
	for i in 0 ..< len(cu.files_order) {
		fi := cu.files_order[i]
		ns := get_namespace(cu, fi.namespace_path)
		seen := make(map[string]int)
		defer delete(seen)

		for decl in fi.file.decls {
			#partial switch d in decl {
			case ast.Rule_Decl:
				if other, ok := seen[d.name.name]; ok {
					add_redeclared(cu, fi, d.name.pos, d.name.name, fi, other)
				} else if other_ref, exists := ns.rules[d.name.name]; exists {
					add_redeclared(cu, fi, d.name.pos, d.name.name, other_ref.file, other_ref.offset)
				} else {
					seen[d.name.name] = d.name.pos
					ns.rules[d.name.name] = Rule_Ref{file = fi, offset = d.name.pos}
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
	cu.namespaces[strings.clone(dir)] = ns
	return ns
}

// check_file performs expression analysis on every rule body in fi.
check_file :: proc(cu: ^Compilation_Unit, fi: ^Loaded_File) {
	if fi.broken do return
	for decl in fi.file.decls {
		#partial switch d in decl {
		case ast.Rule_Decl:
			for body in d.body {
				check_body(cu, fi, d.params[:], body)
			}
		}
	}
}

// check_body checks expr with a rule's parameters in scope.
check_body :: proc(cu: ^Compilation_Unit, fi: ^Loaded_File, params: []ast.Ident, expr: ast.Expr) {
	if is_param(params, expr) do return
	check_expr_scoped(cu, fi, params, expr)
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
check_expr_scoped :: proc(cu: ^Compilation_Unit, fi: ^Loaded_File, params: []ast.Ident, expr: ast.Expr) {
	switch v in expr {
	case ast.Ident:
		if !is_param(params, v) && !is_defined(cu, fi, v.name) {
			add_error(cu, fi.display, fi.src, v.pos, fmt.tprintf("undefined identifier: %s", v.name))
		}
	case ast.Term_Expr:
		check_expr_scoped(cu, fi, params, v.x^)
	case ast.Member_Expr:
		check_member(cu, fi, v)
	case ast.Call_Expr:
		if !is_param(params, v.name) && !is_defined(cu, fi, v.name.name) {
			add_error(cu, fi.display, fi.src, v.name.pos, fmt.tprintf("undefined identifier: %s", v.name.name))
		}
		for arg in v.args {
			check_expr_scoped(cu, fi, params, arg)
		}
	case ast.Sequence_Expr:
		for e in v.exprs do check_expr_scoped(cu, fi, params, e)
	case ast.Alternative_Expr:
		for e in v.exprs do check_expr_scoped(cu, fi, params, e)
	case ast.Optional_Expr:
		for e in v.exprs do check_expr_scoped(cu, fi, params, e)
	case ast.Repetition_Expr:
		for e in v.exprs do check_expr_scoped(cu, fi, params, e)
	case ast.Group_Expr:
		for e in v.exprs do check_expr_scoped(cu, fi, params, e)
	case ast.String_Lit, ast.Regex_Lit, ast.External_Value, ast.Directive_Expr:
	}
}

// check_expr resolves names in expr and reports undefined references.
check_expr :: proc(cu: ^Compilation_Unit, fi: ^Loaded_File, expr: ast.Expr) {
	check_expr_scoped(cu, fi, nil, expr)
}

// check_member validates a member access `receiver.member`: the receiver must
// be a binding to a namespace and the member must be a rule in that namespace.
check_member :: proc(cu: ^Compilation_Unit, fi: ^Loaded_File, m: ast.Member_Expr) {
	object, ok := m.object^.(ast.Ident)
	if !ok {
		add_error(cu, fi.display, fi.src, m.pos, "expected a namespace on the left of '.'")
		return
	}
	if target_dir, found := fi.bindings[object.name]; found {
		ns := cu.namespaces[target_dir]
		if ns == nil do return
		if _, has := ns.rules[m.member.name]; !has {
			ns_name := filepath.base(target_dir)
			add_error(cu, fi.display, fi.src, m.member.pos, fmt.tprintf("%s.%s is undefined. namespace %s has no field %s", object.name, m.member.name, ns_name, m.member.name))
		}
		return
	}
	if is_defined(cu, fi, object.name) {
		add_error(cu, fi.display, fi.src, m.member.pos, fmt.tprintf("expected a namespace, but '%s' is not a namespace", object.name))
		return
	}
	add_error(cu, fi.display, fi.src, object.pos, fmt.tprintf("undefined identifier: %s", object.name))
}

// is_defined reports whether name is a rule in the file's namespace or a
// binding declared in the file.
is_defined :: proc(cu: ^Compilation_Unit, fi: ^Loaded_File, name: string) -> bool {
	if _, ok := fi.bindings[name]; ok do return true
	ns := cu.namespaces[fi.namespace_path]
	if ns == nil do return false
	_, ok := ns.rules[name]
	return ok
}

// add_redeclared reports that name is declared twice, pointing at the first
// declaration.
add_redeclared :: proc(cu: ^Compilation_Unit, fi: ^Loaded_File, offset: int, name: string, other_file: ^Loaded_File, other_offset: int) {
	other_pos := token.position_at(other_file.src, other_offset)
	add_error(
		cu,
		fi.display,
		fi.src,
		offset,
		fmt.tprintf("field %s redeclared in this namespace. (see other declaration at %s:%d:%d)", name, other_file.display, other_pos.line, other_pos.column),
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
	return 0
}

// add_error appends a diagnostic located at offset within src. Both the path
// and the message are cloned onto the heap so the unit can free them.
add_error :: proc(cu: ^Compilation_Unit, display_path: string, src: string, offset: int, message: string) {
	line, col := 1, 1
	if src != "" {
		pos := token.position_at(src, offset)
		line, col = pos.line, pos.column
	}
	append(
		&cu.errors,
		Semantic_Error{
			path = strings.clone(display_path),
			offset = offset,
			line = line,
			col = col,
			message = strings.clone(message),
		},
	)
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