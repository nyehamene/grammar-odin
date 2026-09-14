package lsp

import "core:io"
import "core:log"
import "core:os"
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

// ns_setup creates the scratch directory rel under the test working directory
// and returns its absolute path. The caller must delete the result.
ns_setup :: proc(t: ^testing.T, rel: string) -> string {
	os.remove_all(rel)
	os.make_directory_all(rel)
	cwd, err := os.get_working_directory(context.temp_allocator)
	if err != nil || cwd == "" {
		testing.fail_now(t, "failed to get working directory")
	}
	return strings.concatenate({cwd, "/", rel})
}

@(test)
test_lsp_did_open_publishes_namespace_diagnostics :: proc(t: ^testing.T) {
	dir := ns_setup(t, "cmd/lsp/testdata/scratch/did_open_ns")
	defer os.remove_all("cmd/lsp/testdata/scratch/did_open_ns")
	defer delete(dir)

	// A sibling file that is never opened but lives on disk.
	sib := strings.concatenate({dir, "/sib.grammar"})
	defer delete(sib)
	if err := os.write_entire_file(sib, "bad = missing_rule;\n"); err != nil {
		testing.fail_now(t, "failed to write sibling grammar")
	}

	main_uri := strings.concatenate({"file://", dir, "/main.grammar"})
	defer delete(main_uri)
	params := strings.concatenate({
		`{"textDocument":{"uri":"`,
		main_uri,
		`","languageId":"grammar","version":1,"text":"a = \"x\";"}}`,
	})

	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(`textDocument/didOpen`, params),
		make_request(`2`, `shutdown`, `null`),
	)
	output := send_request(stdin)
	delete(params)

	sib_uri := strings.concatenate({"file://", dir, "/sib.grammar"})
	defer delete(sib_uri)
	testing.expect(
		t,
		strings.contains(output, `"uri":"`) && strings.contains(output, sib_uri),
		"opening a file must publish diagnostics for its sibling namespace files",
	)
	testing.expect(
		t,
		strings.contains(output, "undefined identifier: missing_rule"),
		"namespace diagnostics must include the sibling's error",
	)
}

@(test)
test_lsp_did_open_prefers_open_text_over_disk :: proc(t: ^testing.T) {
	dir := ns_setup(t, "cmd/lsp/testdata/scratch/did_open_disk")
	defer os.remove_all("cmd/lsp/testdata/scratch/did_open_disk")
	defer delete(dir)

	// The on-disk copy has an error, but the opened text is clean; the open
	// text must win when the namespace is loaded.
	main_path := strings.concatenate({dir, "/main.grammar"})
	defer delete(main_path)
	if err := os.write_entire_file(main_path, "bad = disk_only;\n"); err != nil {
		testing.fail_now(t, "failed to write main grammar")
	}

	main_uri := strings.concatenate({"file://", main_path})
	defer delete(main_uri)
	params := strings.concatenate({
		`{"textDocument":{"uri":"`,
		main_uri,
		`","languageId":"grammar","version":1,"text":"a = \"x\";"}}`,
	})

	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(`textDocument/didOpen`, params),
		make_request(`2`, `shutdown`, `null`),
	)
	output := send_request(stdin)
	delete(params)

	testing.expect(
		t,
		!strings.contains(output, "undefined identifier: disk_only"),
		"the opened text must be used instead of the on-disk copy",
	)
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
	testing.expect(t, strings.contains(output, "1:1"))
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

@(test)
test_lsp_references :: proc(t: ^testing.T) {
	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(
			`textDocument/didOpen`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar","languageId":"grammar","version":1,"text":"expr = term | term;\nterm = \"a\";"}}`,
		),
		// Find references on the first `term` (line 0, character 8); the
		// declaration and both usages come back with includeDeclaration.
		make_request(
			`2`,
			`textDocument/references`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar"},"position":{"line":0,"character":8},"context":{"includeDeclaration":true}}`,
		),
		make_request(`3`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	log.debugf("output:\n%v", output)
	testing.expect(t, strings.contains(output, `"id": 2`))
	testing.expect(t, strings.contains(output, `"line":1,"character":0`))
	testing.expect(t, strings.contains(output, `"line":0,"character":7`))
	testing.expect(t, strings.contains(output, `"line":0,"character":14`))
}

@(test)
test_lsp_document_symbol :: proc(t: ^testing.T) {
	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(
			`textDocument/didOpen`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar","languageId":"grammar","version":1,"text":"greet name title = \"hello\" name title;\nbye = \"x\";\nns = @import(\"./base\");"}}`,
		),
		make_request(
			`2`,
			`textDocument/documentSymbol`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar"}}`,
		),
		make_request(`3`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	log.debugf("output:\n%v", output)
	testing.expect(t, strings.contains(output, `"id": 2`))
	testing.expect(t, strings.contains(output, `"name":"greet"`))
	testing.expect(t, strings.contains(output, `"kind":12`))
	testing.expect(t, strings.contains(output, `"name":"bye"`))
	testing.expect(t, strings.contains(output, `"name":"ns"`))
	testing.expect(t, strings.contains(output, `"kind":3`))
	testing.expect(t, strings.contains(output, `"name":"title"`))
}

@(test)
test_lsp_workspace_symbol :: proc(t: ^testing.T) {
	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(
			`textDocument/didOpen`,
			`{"textDocument":{"uri":"file:///tmp/a.grammar","languageId":"grammar","version":1,"text":"greet = \"hi\";\nside = \"x\";"}}`,
		),
		make_notification(
			`textDocument/didOpen`,
			`{"textDocument":{"uri":"file:///tmp/b.grammar","languageId":"grammar","version":1,"text":"departure = \"go\";"}}`,
		),
		make_request(`2`, `workspace/symbol`, `{"query":"gre"}`),
		make_request(`3`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	log.debugf("output:\n%v", output)
	testing.expect(t, strings.contains(output, `"id": 2`))
	testing.expect(t, strings.contains(output, `"name":"greet"`))
	testing.expect(t, strings.contains(output, `"uri":"file:///tmp/a.grammar"`))
	testing.expect(t, !strings.contains(output, `"name":"side"`))
	testing.expect(t, !strings.contains(output, `"name":"departure"`))
}

@(test)
test_lsp_rename :: proc(t: ^testing.T) {
	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(
			`textDocument/didOpen`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar","languageId":"grammar","version":1,"text":"expr = term | term;\nterm = \"a\";"}}`,
		),
		// prepareRename on the first `term` (line 0, character 8).
		make_request(
			`2`,
			`textDocument/prepareRename`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar"},"position":{"line":0,"character":8}}`,
		),
		// Rename `term` to `elem`: affects both usages and the declaration.
		make_request(
			`3`,
			`textDocument/rename`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar"},"position":{"line":0,"character":8},"newName":"elem"}`,
		),
		make_request(`4`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	log.debugf("output:\n%v", output)
	testing.expect(t, strings.contains(output, `"id": 2`))
	testing.expect(t, strings.contains(output, `"placeholder":"term"`))
	testing.expect(t, strings.contains(output, `"id": 3`))
	testing.expect(t, strings.contains(output, `"changes":{`))
	testing.expect(t, strings.contains(output, `"uri":"file:///tmp/test.grammar"`))

	rename_edits_ok := false
	lines := strings.split_lines(output)
	defer delete(lines)
	for line in lines {
		if strings.has_prefix(line, `{"jsonrpc": "2.0", "id": 3`) {
			rename_edits_ok = strings.count(line, `"newText":"elem"`) == 3
		}
	}
	testing.expect(t, rename_edits_ok)
}

@(test)
test_lsp_completion :: proc(t: ^testing.T) {
	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(
			`textDocument/didOpen`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar","languageId":"grammar","version":1,"text":"expr = \"a\";\nterm = \"b\";\npartial = te"}}`,
		),
		// Complete `te` at line 2, character 11 -> rule `term`.
		make_request(
			`2`,
			`textDocument/completion`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar"},"position":{"line":2,"character":11}}`,
		),
		make_request(`3`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	log.debugf("output:\n%v", output)
	testing.expect(t, strings.contains(output, `"id": 2`))
	testing.expect(t, strings.contains(output, `"label":"term"`))
	testing.expect(t, strings.contains(output, `"kind":3`))
	testing.expect(t, strings.contains(output, `"isIncomplete":false`))
	testing.expect(t, !strings.contains(output, `"label":"expr"`))
}

@(test)
test_lsp_completion_member :: proc(t: ^testing.T) {
	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(
			`textDocument/didOpen`,
			`{"textDocument":{"uri":"file:///tmp/a.grammar","languageId":"grammar","version":1,"text":"ns = @import(\"./base\");\nexpr = ns.b;"}}`,
		),
		make_notification(
			`textDocument/didOpen`,
			`{"textDocument":{"uri":"file:///tmp/base.grammar","languageId":"grammar","version":1,"text":"bye = \"x\";"}}`,
		),
		// Complete `ns.b` (line 1, character 12) -> member `bye` of ./base.
		make_request(
			`2`,
			`textDocument/completion`,
			`{"textDocument":{"uri":"file:///tmp/a.grammar"},"position":{"line":1,"character":12}}`,
		),
		make_request(`3`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	log.debugf("output:\n%v", output)
	testing.expect(t, strings.contains(output, `"id": 2`))
	testing.expect(t, strings.contains(output, `"label":"bye"`))
	testing.expect(t, strings.contains(output, `"kind":3`))
}

@(test)
test_lsp_format_document :: proc(t: ^testing.T) {
	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(
			`textDocument/didOpen`,
			`{"textDocument":{"uri":"file:///tmp/fmt.grammar","languageId":"grammar","version":1,"text":"a = \"a\";\nbar = \"bar\";\n"}}`,
		),
		make_request(
			`2`,
			`textDocument/formatting`,
			`{"textDocument":{"uri":"file:///tmp/fmt.grammar"}}`,
		),
		make_request(`3`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	log.debugf("output:\n%v", output)
	testing.expect(t, strings.contains(output, `"id": 2`))
	// The whole document is replaced by the formatted text: `a` is padded to
	// line up with `bar` and the header of both rules is aligned.
	testing.expect(
		t,
		strings.contains(
			output,
			`"result":[{"range":{"start":{"line":0,"character":0},"end":{"line":2,"character":0}},"newText":"a   = \"a\";\nbar = \"bar\";\n"}]`,
		),
	)
}

@(test)
test_lsp_format_already_formatted :: proc(t: ^testing.T) {
	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(
			`textDocument/didOpen`,
			`{"textDocument":{"uri":"file:///tmp/fmt.grammar","languageId":"grammar","version":1,"text":"a   = \"a\";\nbar = \"bar\";\n"}}`,
		),
		make_request(
			`2`,
			`textDocument/formatting`,
			`{"textDocument":{"uri":"file:///tmp/fmt.grammar"}}`,
		),
		// An unknown document yields the same empty-array result.
		make_request(
			`3`,
			`textDocument/formatting`,
			`{"textDocument":{"uri":"file:///tmp/missing.grammar"}}`,
		),
		make_request(`4`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	log.debugf("output:\n%v", output)
	testing.expect(t, strings.contains(output, `"id": 2`))
	testing.expect(t, strings.contains(output, `"result":[]`))
	testing.expect(t, strings.contains(output, `"id": 3`))
}

@(test)
test_lsp_format_syntax_error_is_null :: proc(t: ^testing.T) {
	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(
			`textDocument/didOpen`,
			`{"textDocument":{"uri":"file:///tmp/bad.grammar","languageId":"grammar","version":1,"text":"bad = (\"a\" \"b\";\n"}}`,
		),
		make_request(
			`2`,
			`textDocument/formatting`,
			`{"textDocument":{"uri":"file:///tmp/bad.grammar"}}`,
		),
		make_request(`3`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	log.debugf("output:\n%v", output)
	testing.expect(t, strings.contains(output, `"id": 2`))
	testing.expect(t, strings.contains(output, `"result":null`))
}

@(test)
test_lsp_document_highlight :: proc(t: ^testing.T) {
	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(
			`textDocument/didOpen`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar","languageId":"grammar","version":1,"text":"expr = term | term;\nterm = \"a\";"}}`,
		),
		// Highlight on the first `term` (line 0, character 8).
		make_request(
			`2`,
			`textDocument/documentHighlight`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar"},"position":{"line":0,"character":8}}`,
		),
		make_request(`3`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	log.debugf("output:\n%v", output)
	testing.expect(t, strings.contains(output, `"id": 2`))
	testing.expect(t, strings.contains(output, `"kind":1`))
	testing.expect(t, strings.contains(output, `"line":1,"character":0`))
	testing.expect(t, strings.contains(output, `"line":0,"character":7`))
	testing.expect(t, strings.contains(output, `"line":0,"character":14`))
}

@(test)
test_lsp_semantic_tokens :: proc(t: ^testing.T) {
	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{"textDocument":{"semanticTokens":{}}}}`,
		),
		make_notification(
			`textDocument/didOpen`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar","languageId":"grammar","version":1,"text":"expr = term;\nterm = \"a\";"}}`,
		),
		make_request(
			`2`,
			`textDocument/semanticTokens/full`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar"}}`,
		),
		make_request(`3`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	log.debugf("output:\n%v", output)
	testing.expect(t, strings.contains(output, `"id": 2`))
	testing.expect(t, strings.contains(output, `"data":[0,0,4,0,0`))
	testing.expect(t, strings.contains(output, `,0,1,4,0,0`))
	testing.expect(t, strings.contains(output, `,1,0,4,0,0`))
	testing.expect(t, strings.contains(output, `,0,1,3,4,0,0,0,1,6,0]`))
}

@(test)
test_lsp_document_link :: proc(t: ^testing.T) {
	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(
			`textDocument/didOpen`,
			`{"textDocument":{"uri":"file:///tmp/a.grammar","languageId":"grammar","version":1,"text":"ns = @import(\"./base\");\ngreet = \"hi\";"}}`,
		),
		make_notification(
			`textDocument/didOpen`,
			`{"textDocument":{"uri":"file:///tmp/base.grammar","languageId":"grammar","version":1,"text":"bye = \"x\";"}}`,
		),
		make_request(
			`2`,
			`textDocument/documentLink`,
			`{"textDocument":{"uri":"file:///tmp/a.grammar"}}`,
		),
		make_request(`3`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	log.debugf("output:\n%v", output)
	testing.expect(t, strings.contains(output, `"id": 2`))
	testing.expect(t, strings.contains(output, `"target":"file:///tmp/base.grammar"`))
	testing.expect(t, strings.contains(output, `"start":{"line":0,"character":13}`))
	testing.expect(t, strings.contains(output, `"end":{"line":0,"character":21}`))
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
	write_notification_writer(strings.to_writer(&sb), method, params)
	return strings.to_string(sb)
}

// create_stream_reader packs multiple framed messages into a single reader.
// The messages are already framed by make_request/make_notification, so they
// are concatenated verbatim.
create_stream_reader :: proc(msgs: ..string) -> io.Reader {
	sb := strings.builder_make(context.temp_allocator)
	for m in msgs {
		strings.write_string(&sb, m)
	}
	r := new(strings.Reader, context.temp_allocator)
	stdin := strings.to_reader(r, strings.to_string(sb))
	return stdin
}

// send_request starts the server in test mode over stdin and returns a clone
// of everything written to its output stream.
send_request :: proc(stdin: io.Reader) -> string {
	sb_log := strings.builder_make(context.temp_allocator)
	sb_out := strings.builder_make(context.temp_allocator)

	stdout := strings.to_writer(&sb_out)
	logout := strings.to_writer(&sb_log)
	stderr := logout
	test_mode := true

	args := []string{"lsp"}
	run(args, stdin, logout, stdout, stderr, test_mode)

	return strings.clone(strings.to_string(sb_log), context.temp_allocator)
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
