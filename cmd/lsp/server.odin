package lsp

import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:mem/virtual"
import "core:strings"

Server :: struct {
	arena:                  virtual.Arena,

	// io
	stdin:                  io.Reader,
	logout, stdout, stderr: io.Writer,

	// state
	documents:              map[string]^Document,
	shutdown_requested:     bool,
	initialize_result:      string,
	root_paths:             [dynamic]string,


	// testing
	test_mode:              bool,
}

Document :: struct {
	lang_id: string,
	uri:     string,
	version: int,
	text:    string,
}

Server_init :: proc(
	srv: ^Server,
	stdin: io.Reader,
	logout, stdout, stderr: io.Writer,
	test_mode := false,
	loc := #caller_location,
) {
	assert(srv != nil, loc = loc)
	if err := virtual.arena_init_growing(&srv.arena, 1 * mem.Megabyte); err != nil {
		panic("failed to initialize server arena")
	}
	srv.documents = make(map[string]^Document)
	srv.root_paths = make([dynamic]string)
	srv.logout = logout
	srv.stdout = stdout
	srv.stderr = stderr
	srv.test_mode = test_mode
}

Server_destroy :: proc(srv: ^Server) {
	if srv == nil {
		return
	}
	delete(srv.documents)
	delete(srv.root_paths)
	virtual.arena_free_all(&srv.arena)
}

clone_string :: proc(arena: ^virtual.Arena, s: string) -> string {
	alloc := virtual.arena_allocator(arena)
	ss := strings.clone(s, alloc)
	return ss
}

handle_message :: proc(srv: ^Server, msg: json.Value) -> bool {
	obj, obj_ok := msg.(json.Object)
	if !obj_ok {
		return false
	}

	id, _ := get_request_id(obj)
	method, _ := json_string(obj, "method")

	switch method {
	case "initialize":
		handle_initialize(srv, id, obj)

	case "initialized":

	case "shutdown":
		srv.shutdown_requested = true
		write_response(srv, id, "null")

	case "exit":
		return false

	case "textDocument/didOpen":
		handle_did_open(srv, obj)

	case "textDocument/didChange":
		handle_did_change(srv, obj)

	case "textDocument/didClose":
		handle_did_close(srv, obj)

	case "textDocument/hover":
		handle_hover(srv, id, obj)

	case "textDocument/completion":
		handle_completion(srv, id, obj)

	case "textDocument/definition":
		handle_definition(srv, id, obj)

	case "textDocument/references":
		handle_references(srv, id, obj)

	case "textDocument/documentHighlight":
		handle_document_highlight(srv, id, obj)

	case "textDocument/prepareRename":
		handle_prepare_rename(srv, id, obj)

	case "textDocument/rename":
		handle_rename(srv, id, obj)

	case "textDocument/diagnostic":
		handle_text_document_diagnostic(srv, id, obj)

	case "textDocument/documentSymbol":
		handle_document_symbol(srv, id, obj)

	case "textDocument/semanticTokens/full":
		handle_semantic_tokens_full(srv, id, obj)

	case "workspace/symbol":
		handle_workspace_symbol(srv, id, obj)

	case "textDocument/documentLink":
		handle_document_link(srv, id, obj)
	}

	return true
}

get_request_id :: proc(obj: json.Object) -> (Request_Id, bool) {
	id, id_ok := obj["id"]
	if !id_ok {
		return "", false
	}

	if str, s_ok := id.(json.String); s_ok {
		return str, true
	}

	if num, n_ok := id.(json.Integer); n_ok {
		n := fmt.tprintf("%d", num)
		return n, true
	}

	if num, n_ok := id.(json.Float); n_ok {
		n := fmt.tprintf("%v", num)
		return n, true
	}

	return "", false
}
