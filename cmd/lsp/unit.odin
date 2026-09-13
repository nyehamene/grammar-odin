package lsp

import "../check"

// index_documents builds a compilation unit from every open document, parsing
// each in memory (imports are still resolved from disk) and running the
// checker's binding and semantic phases. The caller owns the returned unit and
// must call check.destroy_compilation_unit on it once finished.
index_documents :: proc(srv: ^Server) -> check.Compilation_Unit {
	cu := check.new_compilation_unit()

	for _, d in srv.documents {
		abs := uri_to_path(d.uri) or_continue
		display := check.display_of(&cu, abs)
		check.load_source(&cu, abs, display, d.text)
	}

	check.run_checks(&cu)
	return cu
}