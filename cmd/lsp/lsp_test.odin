package lsp

import "core:io"
import "core:log"
import "core:strings"
import "core:testing"

@(test)
test_lsp :: proc(t: ^testing.T) {
	stdin := create_request_reader(
		`1`,
		`initialize`,
		`{"clientInfo":{"name": "test", "version": "0.1"}, "capabilities": {"textDocument": {"semanticTokens": {}}}}`,
	)
	output := send_request(stdin)
	testing.expect(
		t,
		strings.contains(output, "client 'test' version 0.1 supports semantic tokens"),
	)
}

@(test)
test_lsp_did_open_publishes_diagnostics :: proc(t: ^testing.T) {
	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(
			`textDocument/didOpen`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar","languageId":"grammar","version":1,"text":"a = b;"}}`,
		),
		make_request(`2`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	log.debugf("output:\n%v", output)
	testing.expect(t, strings.contains(output, `"method":"textDocument/publishDiagnostics"`))
	testing.expect(t, strings.contains(output, "undefined identifier: b"))
}

@(test)
test_lsp_pull_diagnostic :: proc(t: ^testing.T) {
	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(
			`textDocument/didOpen`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar","languageId":"grammar","version":1,"text":"a = b;"}}`,
		),
		make_request(
			`2`,
			`textDocument/diagnostic`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar"}}`,
		),
		make_request(`3`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	log.debugf("output:\n%v", output)
	testing.expect(t, strings.contains(output, `"kind":"full"`))
	testing.expect(t, strings.contains(output, "undefined identifier: b"))
}

@(test)
test_lsp_did_change_updates_diagnostics :: proc(t: ^testing.T) {
	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(
			`textDocument/didOpen`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar","languageId":"grammar","version":1,"text":"a = b;"}}`,
		),
		make_notification(
			`textDocument/didChange`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar","version":2},"contentChanges":[{"text":"a = \"ok\";"}]}`,
		),
		make_request(`2`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	log.debugf("output:\n%v", output)
	testing.expect(t, strings.contains(output, "undefined identifier: b"))
	testing.expect(t, strings.contains(output, `"diagnostics":[]`))
}

@(test)
test_lsp_hover :: proc(t: ^testing.T) {
	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(
			`textDocument/didOpen`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar","languageId":"grammar","version":1,"text":"greeting = \"hi\";"}}`,
		),
		// Hover over the rule name `greeting` at line 0, character 0.
		make_request(
			`2`,
			`textDocument/hover`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar"},"position":{"line":0,"character":0}}`,
		),
		// Hover over the 'h' inside the string literal.
		make_request(
			`3`,
			`textDocument/hover`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar"},"position":{"line":0,"character":13}}`,
		),
		make_request(`4`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	log.debugf("output:\n%v", output)
	testing.expect(t, strings.contains(output, `"id": 2`))
	testing.expect(t, strings.contains(output, "rule `greeting`"))
	testing.expect(t, strings.contains(output, "declared at"))
	testing.expect(t, strings.contains(output, ":1:1"))
	testing.expect(t, strings.contains(output, `"id": 3`))
	testing.expect(t, strings.contains(output, "string literal"))
}

@(test)
test_lsp_definition :: proc(t: ^testing.T) {
	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(
			`textDocument/didOpen`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar","languageId":"grammar","version":1,"text":"expr = term | \"b\";\nterm = \"a\";"}}`,
		),
		// Go-to-definition on the `term` used inside `expr` (line 0, character 8).
		make_request(
			`2`,
			`textDocument/definition`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar"},"position":{"line":0,"character":8}}`,
		),
		make_request(`3`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	log.debugf("output:\n%v", output)
	testing.expect(t, strings.contains(output, `"id": 2`))
	testing.expect(t, strings.contains(output, `"uri":"file:///tmp/test.grammar"`))
	testing.expect(t, strings.contains(output, `"line":1,"character":0`))
}

// make_request builds a single framed JSON-RPC request message.
make_request :: proc(id, method, params: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	write_request(strings.to_writer(&sb), id, method, params)
	return strings.to_string(sb)
}

// make_notification builds a single framed JSON-RPC notification message.
make_notification :: proc(method, params: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	write_notification(strings.to_writer(&sb), method, params)
	return strings.to_string(sb)
}

// create_stream_reader packs multiple framed messages into a single reader.
create_stream_reader :: proc(msgs: ..string) -> io.Reader {
	sb := strings.builder_make(context.temp_allocator)
	for m in msgs {
		write_frame(strings.to_writer(&sb), m)
	}
	r := new(strings.Reader, context.temp_allocator)
	stdin := strings.to_reader(r, strings.to_string(sb))
	return stdin
}

// send_request starts the server in test mode over stdin and returns a clone
// of everything written to its output stream.
send_request :: proc(stdin: io.Reader) -> string {
	sb := strings.builder_make(context.temp_allocator)
	stdout := strings.to_writer(&sb)
	logout := stdout
	stderr := stdout
	test_mode := true

	args := []string{"lsp"}
	run(args, stdin, logout, stdout, stderr, test_mode)

	return strings.clone(strings.to_string(sb), context.temp_allocator)
}

create_request_reader :: proc(id, method, msg: string) -> io.Reader {
	sb := strings.builder_make(context.temp_allocator)
	w := strings.to_writer(&sb)
	write_request(w, id, method, msg)
	req := strings.to_string(sb)

	log.debug(req)

	r := new(strings.Reader, context.temp_allocator)
	stdin := strings.to_reader(r, req)
	return stdin
}
