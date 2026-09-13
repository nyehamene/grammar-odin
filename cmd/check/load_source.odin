package check

import "core:path/filepath"
import "core:strings"

import "../../ast"
import "../../token"

// load_source registers a grammar file whose text is already in memory (e.g. an
// open language server document) with the compilation unit and resolves its
// imports from the file's directory on disk. It mirrors load but takes the
// source text directly instead of reading from disk.
//
// Both abs and display must be owned by the caller. On success the compilation
// unit takes ownership of abs (as the files map key) and display (as the file's
// display path); src is referenced, not copied, and must outlive the unit.
load_source :: proc(cu: ^Compilation_Unit, abs: string, display: string, src: string) -> ^Loaded_File {
	if f, ok := cu.files[abs]; ok {
		delete(abs)
		delete(display)
		return f
	}

	tokens, lex_errors := token.scan(src)
	file, parse_errors := ast.parse_file(src, tokens[:])
	delete(tokens)

	fi := new(Loaded_File)
	fi.display = display
	fi.src = src
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

// run_checks binds all loaded files into their namespaces and performs semantic
// checking on every file, mirroring the analysis phase of check without
// printing the results.
run_checks :: proc(cu: ^Compilation_Unit) {
	bind_all(cu)
	for i in 0 ..< len(cu.files_order) {
		check_file(cu, cu.files_order[i])
	}
}