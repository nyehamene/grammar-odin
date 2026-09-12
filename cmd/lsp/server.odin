package lsp

import "core:encoding/json"
import "core:fmt"
import "core:io"
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

	debugf(srv, "id: %s", id)

	switch method {
	case "initialize":
		handle_initialize(srv, id, obj)

	case "initialized":
	case "shutdown":
	case "exit":
	case "textDocument/didOpen":
	case "textDocument/didChange":
	case "textDocument/documentSymbol":
	case "textDocument/semanticTokens/full":
	case "textDocument/diagnostic":
	case "workspace/symbol":
	case:
		panic(method)
	}

	if srv.test_mode {
		srv.shutdown_requested = true
		return false
	}

	return true
}

get_request_id :: proc(obj: json.Object) -> (Request_Id, bool) {
	if str, ok := json_string(obj, "id"); ok {
		return str, true
	}
	if num, ok := json_int(obj, "id"); ok {
		n := fmt.tprintf("%d", i64(num))
		return json.String(n), true
	}
	return "", false
}
