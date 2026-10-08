package check

import "core:fmt"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:sort"
import "core:strconv"
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

// Rule_Ref identifies a declaration: a rule, or one proc of a name. The arity is the
// parameter count, so it is 0 for a rule and the arity of a proc otherwise.
Rule_Ref :: struct {
	type:       Type,
	arity:      int,
	file:       ^Loaded_File, // the file declaring it
	offset:     int, // source offset of the declaration's name
	decl_index: int,
}

// Use_Counts tallies the references made to one declaration. self counts the
// references made by the declaration's own body, because a declaration that
// references nothing but itself is still unused: reachability is judged by
// whether some *other* declaration names it.
Use_Counts :: struct {
	total: int,
	self:  int,
}

// used_by_other reports whether some declaration other than referrer named this one.
used_by_other :: proc(counts: Use_Counts, referrer: Proc_Key) -> bool {
	return counts.total > counts.self
}

// record_use notes one reference to key made from the declaration referrer.
record_use :: proc(uses: ^map[Proc_Key]Use_Counts, key, referrer: Proc_Key) {
	counts := uses[key]
	counts.total += 1
	if referrer == key do counts.self += 1
	uses[key] = counts
}

// Proc_Key names one proc: a name and the arity it is declared at. Two procs of
// one name are distinct declarations, so a reference to a proc is counted per arity
// rather than per name, and a use of one overload is not a use of another.
Proc_Key :: struct {
	name:  string,
	arity: int,
}

// Proc_Lookup is how a call to a proc resolved. .None is a name nothing is
// declared under; .Wrong_Arity is a name procs are declared under, none of them of
// the arity the call passes arguments at; .Found is the proc the call names.
Proc_Lookup :: enum {
	None,
	Wrong_Arity,
	Found,
}

// Namespace is the collection of declarations made in a directory. Every grammar
// file in the same directory contributes its declarations to the same namespace.
//
// The rules and the procs are held apart. A declaration of no parameters is a rule
// and a declaration of some is a proc, so the two can never be the same declaration
// and a name may be both: `foo = "a";` is a rule of `foo` and `foo x = x;` is a proc
// of it, neither shadowing the other. A name may hold several procs, one per arity.
Namespace :: struct {
	rules: map[string]Rule_Ref,
	procs: map[string][]Rule_Ref,
	uses:  map[Proc_Key]Use_Counts, // declaration -> references to it
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
	private_procs:   map[string][]Rule_Ref,
	private_uses:    map[Proc_Key]Use_Counts, // private declaration -> references to it
	used_bindings:   map[string]bool, // binding name -> referenced in this file
	binding_offsets: map[string]int, // binding name -> offset of the binding's name
	enclosing_rule:  string, // name of the rule whose body is being walked
	enclosing_arity: int, // arity of that rule; a rule is 0, a proc its parameter count
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
		for _, procs in f.private_procs {
			delete(procs)
		}
		delete(f.private_procs)
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
		for _, procs in ns.procs {
			delete(procs)
		}
		delete(ns.procs)
		delete(ns.uses)
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
	fi.private_procs = make(map[string][]Rule_Ref)
	fi.private_uses = make(map[Proc_Key]Use_Counts)
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
		case ast.Binding:
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
			fi.bindings[d.ident.name] = cleaned
			fi.binding_offsets[d.ident.name] = d.ident.pos
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

// bind_all registers every rule and proc in its file's namespace and reports
// duplicate declarations.
//
// A declaration of no parameters is a rule, and the name is the whole of its
// identity, so two of them collide. A declaration of some parameters is a proc, and
// a name and an arity together name one, so `foo x = x;` and `foo x y = x y;` are two
// procs of `foo` rather than a duplicate, while `foo x = x;` and `foo a = a;` are the
// same proc declared twice. A rule and a proc of one name never collide, which is what
// lets `foo = "a";` and `foo x = x;` coexist.
//
// Names that collide within a single file (a rule and a binding, or two bindings) are
// reported as well. Private declarations (`_name`) are registered in the declaring
// file instead of the namespace, so they never collide across files.
bind_all :: proc(cu: ^Compilation_Unit) {
	for i in 0 ..< len(cu.files_order) {
		fi := cu.files_order[i]
		ns := get_namespace(cu, fi.namespace_path)
		seen := make(map[string]int)
		defer delete(seen)
		seen_procs := make(map[Proc_Key]int)
		defer delete(seen_procs)

		for decl in fi.file.decls {
			#partial switch d in decl {
			case ast.Rule:
				if is_malformed_private_name(d.ident.name) {
					add_error(
						cu,
						fi.display,
						fi.src,
						d.ident.pos,
						fmt.tprintf(
							"malformed private rule name %s. a private rule name is an underscore followed by a letter, as in _helper",
							d.ident.name,
						),
					)
				}
				arity := len(d.params)
				if arity > 0 {
					bind_proc(cu, fi, ns, d, arity, &seen_procs)
					continue
				}
				if other, ok := seen[d.ident.name]; ok {
					add_redeclared(cu, fi, d.ident.pos, d.ident.name, fi, other)
				} else if other_ref, exists := ns.rules[d.ident.name]; exists {
					add_redeclared(
						cu,
						fi,
						d.ident.pos,
						d.ident.name,
						other_ref.file,
						other_ref.offset,
					)
				} else {
					seen[d.ident.name] = d.ident.pos
					ref := Rule_Ref{file = fi, offset = d.ident.pos, type = .Production}

					if is_private_rule(d.ident.name) {
						fi.private_rules[d.ident.name] = ref
					} else {
						ns.rules[d.ident.name] = ref
					}
				}
			case ast.Binding:
				if other, ok := seen[d.ident.name]; ok {
					add_redeclared(cu, fi, d.ident.pos, d.ident.name, fi, other)
				} else {
					seen[d.ident.name] = d.ident.pos
				}
			}
		}
	}
}

// bind_proc registers the proc of arity parameters that d declares, and reports it if
// that name and arity are already taken. The procs of a name are held in source order,
// and the ones of a private name (`_name`) in the declaring file rather than the
// namespace, so they never collide across files.
bind_proc :: proc(
	cu: ^Compilation_Unit,
	fi: ^Loaded_File,
	ns: ^Namespace,
	d: ast.Rule,
	arity: int,
	seen: ^map[Proc_Key]int,
) {
	key := Proc_Key{name = d.ident.name, arity = arity}
	if other, ok := seen[key]; ok {
		add_redeclared(cu, fi, d.ident.pos, d.ident.name, fi, other)
		return
	}
	seen[key] = d.ident.pos

	ref := Rule_Ref {
		file   = fi,
		offset = d.ident.pos,
		type   = .Proc,
		arity  = arity,
	}

	// A private name is registered in this file rather than the namespace. The map is
	// taken by pointer because assigning a map to a value copies it, and inserting
	// into the copy would leave the caller's map untouched.
	if is_private_rule(d.ident.name) {
		append_proc(&fi.private_procs, d.ident.name, ref)
		return
	}
	append_proc(&ns.procs, d.ident.name, ref)
}

// append_proc adds ref to the procs declared as name, in source order. The list cannot
// be grown after it is built, so it is copied out one longer each time a name gains an
// arity. There are few procs to one name, so the copy costs less than the bookkeeping a
// counted two-pass fill would need.
append_proc :: proc(procs: ^map[string][]Rule_Ref, name: string, ref: Rule_Ref) {
	declared := procs^[name]
	grown := make([]Rule_Ref, len(declared)+1)
	copy(grown[:], declared)
	grown[len(declared)] = ref
	delete(declared)
	procs^[name] = grown
}

// get_namespace returns the namespace for dir, creating it on first use.
get_namespace :: proc(cu: ^Compilation_Unit, dir: string) -> ^Namespace {
	if ns, ok := cu.namespaces[dir]; ok do return ns
	ns := new(Namespace)
	ns.rules = make(map[string]Rule_Ref)
	ns.procs = make(map[string][]Rule_Ref)
	ns.uses = make(map[Proc_Key]Use_Counts)
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
		case ast.Rule:
			// Record which declaration is being walked, and at what arity, so that a
			// reference can tell whether it came from that declaration itself. The arity
			// is part of that, since the procs of a name are distinct declarations.
			fi.enclosing_rule = d.ident.name
			fi.enclosing_arity = len(d.params)
			check_body(cu, fi, d.params, d.production)
			fi.enclosing_rule = ""
			fi.enclosing_arity = 0
			if len(d.params) > 0 {
				check_unused_params(cu, fi, d.params, d.production)
			}
		}
	}
	check_unused_private_declarations(cu, fi)
	check_unused_bindings(cu, fi)
}

// check_unused_private_declarations warns about every private declaration of fi that
// no other declaration in the same file references. A declaration that was rejected
// as a redeclaration is not registered, and is already reported as an error, so it is
// skipped here. The declarations are walked in source order so the warnings come out
// deterministically.
//
// Each proc of a name is a declaration of its own, so a name with two arities is
// reported per arity and one that is called counts only for the arity it is called at.
check_unused_private_declarations :: proc(cu: ^Compilation_Unit, fi: ^Loaded_File) {
	for decl in fi.file.decls {
		#partial switch d in decl {
		case ast.Rule:
			if !is_private_rule(d.ident.name) do continue
			arity := len(d.params)
			key := Proc_Key{name = d.ident.name, arity = arity}

			if arity > 0 {
				// A declaration that lost a redeclaration contest was never
				// registered; the one that won was, and its offset tells them apart.
				declared, ok := find_proc(fi.private_procs[d.ident.name], arity, d.ident.pos)
				if !ok do continue
				if used_by_other(fi.private_uses[key], key) do continue
				add_warning(
					cu,
					fi.display,
					fi.src,
					d.ident.pos,
					fmt.tprintf(
						"unused private proc: %s with %d parameter%s",
						d.ident.name,
						arity,
						plural(arity),
					),
				)
				continue
			}

			if ref, ok := fi.private_rules[d.ident.name]; !ok || ref.offset != d.ident.pos {
				continue
			}
			if used_by_other(fi.private_uses[key], key) do continue
			add_warning(
				cu,
				fi.display,
				fi.src,
				d.ident.pos,
				fmt.tprintf("unused private rule: %s", d.ident.name),
			)
		}
	}
}

// find_proc returns the proc of arity in procs, and whether it is declared at offset.
// The offset is what tells the registered declaration from one that lost a
// redeclaration contest and was never registered.
find_proc :: proc(procs: []Rule_Ref, arity, offset: int) -> (Rule_Ref, bool) {
	for ref in procs {
		if ref.arity == arity && ref.offset == offset do return ref, true
	}
	return {}, false
}

// plural is the plural suffix for a count of things.
plural :: proc(count: int) -> string {
	return "" if count == 1 else "s"
}

// check_unused_bindings warns about every import binding of fi that no rule
// body references. A binding whose import failed is skipped: it is already an
// error, and it was never registered, so nothing could have referenced it.
check_unused_bindings :: proc(cu: ^Compilation_Unit, fi: ^Loaded_File) {
	for decl in fi.file.decls {
		#partial switch d in decl {
		case ast.Binding:
			if _, ok := fi.bindings[d.ident.name]; !ok do continue
			if fi.used_bindings[d.ident.name] do continue
			add_warning(
				cu,
				fi.display,
				fi.src,
				d.ident.pos,
				fmt.tprintf("unused binding: %s", d.ident.name),
			)
		}
	}
}

// check_unused_local_declarations warns about every local declaration of every loaded
// file that no other declaration in its namespace references. Exported declarations
// are never reported: an importing namespace may reference one that nothing inside
// its own namespace does.
//
// Each proc of a name is reported on its own, at the arity it is declared, since the
// procs of a name are distinct declarations and one that is called says nothing about
// the others.
//
// Local declarations are counted per namespace rather than per file, so this runs once
// over the whole unit after every file body has been walked.
check_unused_local_declarations :: proc(cu: ^Compilation_Unit) {
	for i in 0 ..< len(cu.files_order) {
		fi := cu.files_order[i]
		if fi.broken do continue
		ns := cu.namespaces[fi.namespace_path]
		if ns == nil do continue

		for decl in fi.file.decls {
			#partial switch d in decl {
			case ast.Rule:
				if !is_local_rule(d.ident.name) do continue
				arity := len(d.params)
				key := Proc_Key{name = d.ident.name, arity = arity}

				if arity > 0 {
					// As with private declarations, only the one that was actually
					// registered can be reported; Rule_Ref.offset says which it was.
					if _, ok := find_proc(ns.procs[d.ident.name], arity, d.ident.pos); !ok {
						continue
					}
					if used_by_other(ns.uses[key], key) do continue
					add_warning(
						cu,
						fi.display,
						fi.src,
						d.ident.pos,
						fmt.tprintf(
							"unused local proc: %s with %d parameter%s",
							d.ident.name,
							arity,
							plural(arity),
						),
					)
					continue
				}

				// As with private rules, only the declaration that was actually
				// registered can be reported; Rule_Ref.offset says which it was.
				if ref, ok := ns.rules[d.ident.name]; !ok || ref.offset != d.ident.pos {
					continue
				}
				if used_by_other(ns.uses[key], key) do continue
				add_warning(
					cu,
					fi.display,
					fi.src,
					d.ident.pos,
					fmt.tprintf("unused local rule: %s", d.ident.name),
				)
			}
		}
	}
}

// check_unused_params reports every proc parameter that is never referenced in
// the rule body.
check_unused_params :: proc(
	cu: ^Compilation_Unit,
	fi: ^Loaded_File,
	params: []ast.Ident,
	production: ast.Production,
) {
	for p in params {
		if uses_param(production, p.name) do continue
		add_error(cu, fi.display, fi.src, p.pos, fmt.tprintf("unused proc parameter: %s", p.name))
	}
}

// uses_param reports whether param appears as an identifier anywhere in production.
uses_param :: proc(production: ast.Production, param: string) -> bool {
	switch v in production {
	case ast.Ident:
		return v.name == param
	case ast.String_Lit, ast.Regex_Lit, ast.External_Value, ast.Directive:
		return false
	case ast.Qual_Ident:
		return uses_param(v.lhs, param) || uses_param(v.rhs, param)
	case ^ast.Call:
		// The callee names a rule rather than a value, so only a plain receiver
		// can be the parameter; the arguments are the value positions of a call,
		// and a parameter passed to one is a use of it.
		switch it in v.ident {
		case ast.Ident:
			if uses_param(it, param) do return true
		case ast.Qual_Ident:
			if uses_param(it.lhs, param) do return true
		}
		return productions_use_param(v.args, param)

	case ast.Sequence:
		return productions_use_param(v.productions, param)
	case ^ast.Alternative:
		return uses_param(v.lhs, param) || uses_param(v.rhs, param)
	case ^ast.Optional:
		return uses_param(v.production, param)
	case ^ast.Repetition:
		return uses_param(v.production, param)
	case ^ast.Group:
		return uses_param(v.production, param)
	case ^ast.Tagged_Production:
		return uses_param(v.production, param)
	}
	return false
}

productions_use_param :: proc(productions: []ast.Production, param: string) -> bool {
	for e in productions {
		if uses_param(e, param) do return true
	}
	return false
}

// check_body checks the production of a rule with its parameters in scope. A
// rule names one production, and that production stands where a value is
// expected, so a body that is nothing but a reference to a proc or to a
// namespace is rejected: the rule has to call the proc or select from the
// namespace. Every other shape yields a Production operand and is left to the
// checks inside the production.
check_body :: proc(
	cu: ^Compilation_Unit,
	fi: ^Loaded_File,
	params: []ast.Ident,
	production: ast.Production,
) {
	o: Operand
	check_production_scoped(cu, fi, params, production, &o)

	// A proc used as a production is reported where it is resolved, since that is
	// where the tables are read, so nothing is left to say here about the type.
	if o.kind == .LValue do return

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
}

// check_callee resolves the proc a call names at the number of arguments the call
// passes. A name declared as no proc of that arity is reported with the arities it is
// declared at, since those are the calls that would have worked.
check_callee :: proc(
	cu: ^Compilation_Unit,
	fi: ^Loaded_File,
	name: ast.Ident,
	arity: int,
	o: ^Operand,
) {
	ref, how := Resolve_Proc(cu, fi, name.name, arity)
	switch how {
	case .Found:
		mark_proc_used(cu, fi, name.name, arity)
		Operand_lvalue(o, .Proc, name.pos, name.name)
		o.arity = arity
		return
	case .Wrong_Arity:
		Operand_invalid(o, name.pos, name.name)
		// The suggestion is built in a builder this frame owns, since a string
		// allocated in a helper of its own would not outlive that helper.
		sb := strings.builder_make(context.temp_allocator)
		defer strings.builder_destroy(&sb)
		write_arity_list(cu, fi, name.name, &sb)

		add_error(
			cu,
			fi.display,
			fi.src,
			name.pos,
			fmt.tprintf(
				"proc '%s' has no overload with arity %d. Did you mean to pass %s.",
				name.name,
				arity,
				strings.to_string(sb),
			),
		)
		return
	case .None:
		// A name declared as a rule is declared, but a rule is not callable, and the
		// caller says so in as many words. Only a name declared nowhere is undefined.
		if _, is_rule := Resolve_Rule(cu, fi, name.name); is_rule {
			mark_rule_used(cu, fi, name.name)
			Operand_lvalue(o, .Production, name.pos, name.name)
			return
		}
		Operand_invalid(o, name.pos, name.name)
		add_error(
			cu,
			fi.display,
			fi.src,
			name.pos,
			fmt.tprintf("undefined identifier: %s", name.name),
		)
		return
	}
}

// write_arity_list writes the arities a name is declared at into sb, ascending, as the
// suggestion in a no-overload message: `1 or 2`. They are the calls that would have
// worked, so they are the whole of the advice; there is no edit distance here, since a
// call of the wrong arity is not a misspelled name.
//
// The arities are gathered and sorted rather than read off the declarations, because a
// name may be declared out of arity order across the files of a namespace. There are
// few procs to one name, so the copy costs less than the bookkeeping.
write_arity_list :: proc(
	cu: ^Compilation_Unit,
	fi: ^Loaded_File,
	name: string,
	sb: ^strings.Builder,
) {
	ns := cu.namespaces[fi.namespace_path]
	declared := make([dynamic]int, 0, 4, context.allocator)
	defer delete(declared)

	collect_proc_arities(fi.private_procs[name], &declared)
	if ns != nil do collect_proc_arities(ns.procs[name], &declared)
	if len(declared) == 0 {
		strings.write_string(sb, "arguments")
		return
	}


	sort.quick_sort_proc(declared[:], cmp_int_ascending)

	last := len(declared) - 1
	for arity, i in declared {
		if i > 0 {
			// An English list closes with `or`, which is preceded by a comma only once
			// there is something before it: `1 or 2`, `1, 2 or 3`.
			switch i {
			case last:
				strings.write_string(sb, i == 1 ? " or " : ", or ")
			case:
				strings.write_string(sb, ", ")
			}
		}
		// A parameter count is small enough to render in a fixed buffer, which keeps
		// the suggestion free of an allocation per arity.
		digits: [20]byte
		strings.write_string(sb, strconv.write_int(digits[:], i64(arity), 10))
	}

	strings.write_string(sb, " argument")
	// The suffix agrees with the last count, so `0 or 1 argument` is singular.
	if declared[last] != 1 do strings.write_string(sb, "s")
}

collect_proc_arities :: proc(procs: []Rule_Ref, out: ^[dynamic]int) {
	for ref in procs {
		append(out, ref.arity)
	}
}

// cmp_int_ascending orders two counts from the smaller to the larger.
cmp_int_ascending :: proc(a, b: int) -> int {
	if a < b do return -1
	if a > b do return 1
	return 0
}

// is_param reports whether production is one of the given parameters.
is_param :: proc(params: []ast.Ident, production: ast.Production) -> bool {
	ident, ok := production.(ast.Ident)
	if !ok do return false
	for p in params {
		if p.name == ident.name do return true
	}
	return false
}

// check_production_scoped is check_production with a parameter list in scope.
check_production_scoped :: proc(
	cu: ^Compilation_Unit,
	fi: ^Loaded_File,
	params: []ast.Ident,
	production: ast.Production,
	o: ^Operand,
) {

	switch v in production {
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

		rule, defined := Resolve_Rule(cu, fi, v.name)
		if !defined {
			Operand_invalid(o, v.pos, v.name)
			// A name declared only as procs is declared, but a proc is not a rule, so
			// saying which it is beats saying the name is not there.
			if Has_Proc(cu, fi, v.name) {
				add_error(
					cu,
					fi.display,
					fi.src,
					v.pos,
					fmt.tprintf("proc cannot be used as a production: %s", v.name),
				)
			} else {
				add_error(
					cu,
					fi.display,
					fi.src,
					v.pos,
					fmt.tprintf("undefined identifier: %s", v.name),
				)
			}
			break
		}
		mark_rule_used(cu, fi, v.name)
		Operand_lvalue(o, rule.type, v.pos, v.name)
		o.arity = rule.arity

	case ast.Qual_Ident:
		check_member(cu, fi, v, 0, o)

	case ^ast.Call:
		// A call names a proc, resolved at the number of arguments it passes, which is
		// what tells the procs of that name apart. A parameter or a binding in callee
		// position is a mistake either way, and the checks that report them look at the
		// name the same way a production reference does.
		arity := len(v.args)
		name_op: Operand
		switch it in v.ident {
		case ast.Ident:
			if is_param(params, it) || is_binding(fi, it.name) {
				check_production_scoped(cu, fi, params, it, &name_op)
				break
			}
			check_callee(cu, fi, it, arity, &name_op)
		case ast.Qual_Ident:
			check_member(cu, fi, it, arity, &name_op)
		}
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

		Operand_lvalue(o, .Production, v.pos, name_op.name)

		for arg in v.args {
			arg_op: Operand
			check_production_scoped(cu, fi, params, arg, &arg_op)
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

	case ast.Sequence:
		check_production_group(cu, fi, params, v.pos, v.productions, o)

	case ^ast.Alternative:
		check_production_scoped(cu, fi, params, v.lhs, o)
		check_production_scoped(cu, fi, params, v.rhs, o)

	case ^ast.Optional:
		check_production_scoped(cu, fi, params, v.production, o)

	case ^ast.Repetition:
		check_production_scoped(cu, fi, params, v.production, o)

	case ^ast.Group:
		check_production_scoped(cu, fi, params, v.production, o)

	case ^ast.Tagged_Production:
		// A tag annotates the production it follows, so it is checked, and
		// yields an operand, exactly as the untagged production would.
		check_production_scoped(cu, fi, params, v.production, o)

	case ast.String_Lit:
		Operand_lvalue(o, .String, v.pos, v.value)

	case ast.Regex_Lit:
		Operand_lvalue(o, .Regexp, v.pos, v.value)

	case ast.External_Value:
		Operand_rvalue(o, .External, v.pos, v.name)

	case ast.Directive:
		// Operand_rvalue(o, .Unknown, v.pos, v.ident.name)
		Operand_invalid(o, v.pos, v.ident.name)
	}
}

check_production_group :: proc(
	cu: ^Compilation_Unit,
	fi: ^Loaded_File,
	params: []ast.Ident,
	pos: int,
	productions: []ast.Production,
	o: ^Operand,
) {
	for e in productions {
		eop: Operand
		check_production_scoped(cu, fi, params, e, &eop)
	}
	Operand_lvalue(o, .Production, pos)
}

// check_production resolves names in production and reports undefined references.
check_production :: proc(cu: ^Compilation_Unit, fi: ^Loaded_File, production: ast.Production, o: ^Operand) {
	check_production_scoped(cu, fi, nil, production, o)
}

// check_member validates a member access `receiver.member`: the receiver must
// be a binding to a namespace and the member must be a rule in that namespace.
check_member :: proc(
	cu: ^Compilation_Unit,
	fi: ^Loaded_File,
	m: ast.Qual_Ident,
	arity: int,
	o: ^Operand,
) {
	obj_op: Operand
	check_production(cu, fi, m.lhs, &obj_op)
	if obj_op.kind != .Namespace {
		if obj_op.kind == .Invalid {
			add_error(cu, fi.display, fi.src, m.pos, "expected a namespace on the left of '.'")
			return
		}
		add_error(
			cu,
			fi.display,
			fi.src,
			m.rhs.pos,
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
		if !is_exported_rule(m.rhs.name) {
			// Only an exported rule crosses a namespace boundary. A local or
			// private rule of the target namespace is present but unreachable,
			// which is a different mistake from naming a rule that is not there.
			add_error(
				cu,
				fi.display,
				fi.src,
				m.rhs.pos,
				fmt.tprintf(
					"%s.%s is not exported. only a rule whose name starts with an uppercase letter is accessible from another namespace",
					obj_name,
					m.rhs.name,
				),
			)
			return
		}
		key := Proc_Key{name = m.rhs.name, arity = arity}
		if arity > 0 {
			if _, has := Lookup_Proc(ns.procs[m.rhs.name], arity); !has {
				ns_name := filepath.base(target_dir)
				add_error(
					cu,
					fi.display,
					fi.src,
					m.rhs.pos,
					fmt.tprintf(
						"%s.%s is undefined. namespace %s has no field %s",
						obj_name,
						m.rhs.name,
						ns_name,
						m.rhs.name,
					),
				)
				return
			}
			// The member resolves in another namespace, which is not where the
			// referencing file's declarations live, so mark the target directly.
			mark_namespace_declaration_used(ns, key)
			return
		}
		if _, has := ns.rules[m.rhs.name]; !has {
			ns_name := filepath.base(target_dir)
			add_error(
				cu,
				fi.display,
				fi.src,
				m.rhs.pos,
				fmt.tprintf(
					"%s.%s is undefined. namespace %s has no field %s",
					obj_name,
					m.rhs.name,
					ns_name,
					m.rhs.name,
				),
			)
			return
		}
		// The member resolves in another namespace, which is not where the
		// referencing file's declarations live, so mark the target directly.
		mark_namespace_declaration_used(ns, key)
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

// enclosing returns the key of the declaration whose body is being walked, which is
// what a reference is measured against so that a declaration referencing itself does
// not count as a use of itself.
enclosing :: proc(fi: ^Loaded_File) -> Proc_Key {
	return Proc_Key{name = fi.enclosing_rule, arity = fi.enclosing_arity}
}

// mark_rule_used records a reference to the rule name made from the body being
// walked, routing it to the private or the namespace use set as appropriate. It is
// called only after the name resolves, so a failed lookup records nothing. A rule is
// the arity-zero declaration of its name, so that is the key it is counted under.
mark_rule_used :: proc(cu: ^Compilation_Unit, fi: ^Loaded_File, name: string) {
	key := Proc_Key{name = name}
	if _, ok := fi.private_rules[name]; ok {
		record_use(&fi.private_uses, key, enclosing(fi))
		return
	}
	if ns := cu.namespaces[fi.namespace_path]; ns != nil {
		record_use(&ns.uses, key, enclosing(fi))
	}
}

// mark_proc_used records a reference to the proc of arity named, made from the body
// being walked. It is counted under that proc's own key, so a call of one arity is
// not a use of the procs of the other arities of that name.
mark_proc_used :: proc(cu: ^Compilation_Unit, fi: ^Loaded_File, name: string, arity: int) {
	key := Proc_Key{name = name, arity = arity}
	if _, ok := fi.private_procs[name]; ok {
		record_use(&fi.private_uses, key, enclosing(fi))
		return
	}
	if ns := cu.namespaces[fi.namespace_path]; ns != nil {
		record_use(&ns.uses, key, enclosing(fi))
	}
}

// mark_namespace_declaration_used records a reference to a declaration of ns made
// from another namespace, through an import. There is no enclosing declaration on the
// other side of the boundary, so the reference cannot be a self-reference.
mark_namespace_declaration_used :: proc(ns: ^Namespace, key: Proc_Key) {
	record_use(&ns.uses, key, Proc_Key{})
}

// Resolve_Rule returns the rule declared as name, which is the arity-zero declaration
// of that name. A name with only procs has no rule, since a proc is not one. It is
// exported so that the language server resolves names the way this does, rather than
// keeping a copy of the lookup.
Resolve_Rule :: proc(cu: ^Compilation_Unit, fi: ^Loaded_File, name: string) -> (Rule_Ref, bool) {
	if priv_rule, ok := fi.private_rules[name]; ok {
		return priv_rule, true
	}
	ns := cu.namespaces[fi.namespace_path]
	if ns == nil do return {}, false
	rule, ok := ns.rules[name]
	return rule, ok
}

// Resolve_Proc returns the proc declared as name at arity, and how the lookup came
// out. .Wrong_Arity says the name is declared, but not at that arity, which is what
// separates a call that passed the wrong number of arguments from one that named
// nothing at all.
Resolve_Proc :: proc(
	cu: ^Compilation_Unit,
	fi: ^Loaded_File,
	name: string,
	arity: int,
) -> (ref: Rule_Ref, how: Proc_Lookup) {
	if ref, ok := Lookup_Proc(fi.private_procs[name], arity); ok {
		return ref, .Found
	}
	private_declared := len(fi.private_procs[name]) > 0

	ns := cu.namespaces[fi.namespace_path]
	if ns != nil {
		if ref, ok := Lookup_Proc(ns.procs[name], arity); ok {
			return ref, .Found
		}
		if len(ns.procs[name]) > 0 do return {}, .Wrong_Arity
	}

	if private_declared do return {}, .Wrong_Arity
	return {}, .None
}

// Lookup_Proc returns the proc of arity among procs, which are held in source order,
// and whether one is there.
Lookup_Proc :: proc(procs: []Rule_Ref, arity: int) -> (Rule_Ref, bool) {
	for ref in procs {
		if ref.arity == arity do return ref, true
	}
	return {}, false
}

// Has_Proc reports whether name is declared as a proc of any arity, which is what
// tells a name with no arity-zero declaration from a name that is not declared at all.
Has_Proc :: proc(cu: ^Compilation_Unit, fi: ^Loaded_File, name: string) -> bool {
	if len(fi.private_procs[name]) > 0 do return true
	ns := cu.namespaces[fi.namespace_path]
	if ns == nil do return false
	return len(ns.procs[name]) > 0
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
			path = strings.clone(display_path),
			offset = offset,
			line = line,
			col = col,
			severity = severity,
			message = strings.clone(message),
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
