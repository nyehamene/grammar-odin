package lsp

import "../check"

// index_documents builds a compilation unit from every open document, parsing
// each in memory (imports are still resolved from disk) and running the
// checker's binding and semantic phases. The caller owns the returned unit and
// must call check.destroy_compilation_unit on it once finished.
index_documents :: proc(srv: ^Server) -> check.Compilation_Unit {
	cu := check.new_compilation_unit()
	index_open_documents(srv, &cu)
	check.run_checks(&cu)
	return cu
}

// index_open_documents loads every open document into cu from its in-memory
// text so that unsaved edits are reflected in the analysis.
index_open_documents :: proc(srv: ^Server, cu: ^check.Compilation_Unit) {
	for _, d in srv.documents {
		abs := uri_to_path(d.uri) or_continue
		display := check.display_of(cu, abs)
		check.load_source(cu, abs, display, d.text)
	}
}

// index_namespace builds a compilation unit from every open document plus every
// grammar file in the namespace tree rooted at ns_dir that is not already open,
// then runs the checker's binding and semantic phases. The caller owns the
// returned unit and must call check.destroy_compilation_unit once finished.
index_namespace :: proc(srv: ^Server, ns_dir: string) -> check.Compilation_Unit {
	cu := check.new_compilation_unit()
	index_open_documents(srv, &cu)
	check.load_namespace(&cu, ns_dir)
	check.run_checks(&cu)
	return cu
}