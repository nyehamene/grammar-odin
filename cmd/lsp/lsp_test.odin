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
			`{"textDocument":{"uri":"file:///tmp/test.grammar","languageId":"grammar","version":1,"text":"A = b;"}}`,
		),
		make_notification(
			`textDocument/didChange`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar","version":2},"contentChanges":[{"text":"A = \"ok\";"}]}`,
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
	testing.expect(t, strings.contains(output, `"kind":"markdown"`))
	// A hover reports what a name is declared as, where it is declared, and the
	// declaration itself.
	testing.expect(t, strings.contains(output, "rule: greeting"))
	testing.expect(t, strings.contains(output, "declared at:"))
	testing.expect(t, strings.contains(output, "1:1"))
	testing.expect(t, strings.contains(output, `greeting = \"hi\";`))
	testing.expect(t, strings.contains(output, `"id": 3`))
	testing.expect(t, strings.contains(output, "**type:** string literal"))
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

// A tag annotates the production before it and names nothing itself, so every
// feature must look straight through it into that production, however many
// elements the production has.
@(test)
test_lsp_references_through_a_tag :: proc(t: ^testing.T) {
	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}}`,
		),
		make_notification(
			`textDocument/didOpen`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar","languageId":"grammar","version":1,"text":"expr = other term `+"`"+`name=\"a\"`+"`"+` | term;\nother = \"b\";\nterm = \"a\";"}}`,
		),
		// References on `term`, the second element of the tagged production
		// (line 0, character 13).
		make_request(
			`2`,
			`textDocument/references`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar"},"position":{"line":0,"character":13},"context":{"includeDeclaration":true}}`,
		),
		// Hover on that same element.
		make_request(
			`3`,
			`textDocument/hover`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar"},"position":{"line":0,"character":13}}`,
		),
		// Definition of the first element of the tagged production.
		make_request(
			`4`,
			`textDocument/definition`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar"},"position":{"line":0,"character":7}}`,
		),
		make_request(`5`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	log.debugf("output:\n%v", output)
	// The declaration and both usages of `term` come back, the one inside the
	// tagged production included.
	testing.expect(t, strings.contains(output, `"id": 2`))
	testing.expect(t, strings.contains(output, `"line":2,"character":0`))
	testing.expect(t, strings.contains(output, `"line":0,"character":13`))
	testing.expect(t, strings.contains(output, `"line":0,"character":35`))
	// Hover resolves inside the tagged production rather than reporting nothing.
	testing.expect(t, strings.contains(output, `"id": 3`))
	testing.expect(t, strings.contains(output, "rule: term"))
	// So does definition, for every element of it.
	testing.expect(t, strings.contains(output, `"id": 4`))
	testing.expect(t, strings.contains(output, `"line":1,"character":0`))
}

// A private rule (`_name`) is only visible in the file that declares it, so
// references, rename, hover and definition must all stay inside that file even
// when a sibling file in the same namespace declares a rule with the same name.
@(test)
test_lsp_private_rule_is_file_scoped :: proc(t: ^testing.T) {
	dir := ns_setup(t, "cmd/lsp/testdata/scratch/private_rule")
	defer os.remove_all("cmd/lsp/testdata/scratch/private_rule")
	defer delete(dir)

	a_uri := strings.concatenate({"file://", dir, "/a.grammar"})
	defer delete(a_uri)
	a_open := doc_params(
		a_uri,
		`,"languageId":"grammar","version":1,"text":"_item = \"a\";\nuse = _item _item;"}}`,
	)
	defer delete(a_open)
	a_use := doc_params(a_uri, `},"position":{"line":1,"character":6}}`)
	defer delete(a_use)
	a_refs := doc_params(
		a_uri,
		`},"position":{"line":1,"character":6},"context":{"includeDeclaration":true}}`,
	)
	defer delete(a_refs)
	a_decl := doc_params(a_uri, `},"position":{"line":0,"character":0}}`)
	defer delete(a_decl)
	a_rename := doc_params(a_uri, `},"position":{"line":1,"character":6},"newName":"_thing"}`)
	defer delete(a_rename)

	b_uri := strings.concatenate({"file://", dir, "/b.grammar"})
	defer delete(b_uri)
	b_open := doc_params(
		b_uri,
		`,"languageId":"grammar","version":1,"text":"_item = \"b\";"}}`,
	)
	defer delete(b_open)

	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(`textDocument/didOpen`, a_open),
		make_notification(`textDocument/didOpen`, b_open),
		// References on the first `_item` use (line 1, character 6).
		make_request(`2`, `textDocument/references`, a_refs),
		// Go to definition on the same use.
		make_request(`3`, `textDocument/definition`, a_use),
		// Hover on the private rule declaration (line 0, character 0).
		make_request(`4`, `textDocument/hover`, a_decl),
		// Rename the private rule; only a.grammar may be edited.
		make_request(`5`, `textDocument/rename`, a_rename),
		make_request(`6`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	log.debugf("output:\n%v", output)

	// didOpen publishes diagnostics for the whole namespace, so both URIs
	// appear in the output stream; every assertion below is scoped to a single
	// response line.
	refs := response_for(output, `2`)
	testing.expect(t, refs != "")
	// The declaration plus both uses, all in a.grammar.
	testing.expect(t, strings.contains(refs, "/a.grammar"))
	testing.expect(t, strings.contains(refs, `"line":0,"character":0`))
	testing.expect(t, strings.contains(refs, `"line":1,"character":6`))
	testing.expect(t, strings.contains(refs, `"line":1,"character":12`))
	testing.expect(
		t,
		!strings.contains(refs, "/b.grammar"),
		"a private rule must not pick up references from a sibling file",
	)

	// Definition resolves to the private declaration in the declaring file.
	def := response_for(output, `3`)
	testing.expect(t, strings.contains(def, "/a.grammar"))
	testing.expect(t, strings.contains(def, `"line":0,"character":0`))

	// Hover reports the private declaration as a bare line:column, which is what
	// distinguishes a private rule from a namespace rule.
	hover := response_for(output, `4`)
	testing.expect(t, strings.contains(hover, "rule: _item"))
	// A private declaration is reachable only from its own file, so it is located by
	// line and column rather than by a path that would repeat what they say.
	testing.expect(t, strings.contains(hover, "declared at: 1:1"))
	testing.expect(t, strings.contains(hover, `_item = \"a\";`))

	// Rename rewrites the three occurrences in a.grammar and nothing in b.
	renamed := response_for(output, `5`)
	testing.expect(t, strings.count(renamed, `"newText":"_thing"`) == 3)
	testing.expect(t, !strings.contains(renamed, "/b.grammar"))
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
	// A proc is listed with its parameter list, so the procs of one name are
	// told apart in the outline rather than repeated under one name.
	testing.expect(t, strings.contains(output, `"name":"greet(name, title)"`))
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
test_lsp_completion_member_offers_only_exported_rules :: proc(t: ^testing.T) {
	// `helper` is a local rule of ./base: it is in that namespace, but it is not
	// exported, so completing a member of ./base must not offer it.
	dir := ns_setup(t, "cmd/lsp/testdata/scratch/completion_member")
	defer os.remove_all("cmd/lsp/testdata/scratch/completion_member")
	defer delete(dir)

	base_dir := strings.concatenate({dir, "/base"})
	defer delete(base_dir)
	os.make_directory_all(base_dir)
	rgram := strings.concatenate({base_dir, "/r.grammar"})
	defer delete(rgram)
	if err := os.write_entire_file(rgram, "Exported = \"x\";\nhelper = \"y\";\n"); err != nil {
		testing.fail_now(t, "failed to write the imported namespace")
	}

	a_uri := strings.concatenate({"file://", dir, "/a.grammar"})
	defer delete(a_uri)
	a_open := doc_params(
		a_uri,
		`,"languageId":"grammar","version":1,"text":"ns = @import(\"./base\");\nexpr = ns.Exported;"}}`,
	)
	defer delete(a_open)
	// The cursor sits just after the dot, so the prefix is empty and every rule
	// of ./base is a candidate for the filter to reject.
	a_pos := doc_params(a_uri, `},"position":{"line":1,"character":10}}`)
	defer delete(a_pos)

	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(`textDocument/didOpen`, a_open),
		make_request(`2`, `textDocument/completion`, a_pos),
		make_request(`3`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	log.debugf("output:\n%v", output)
	testing.expect(t, strings.contains(output, `"label":"Exported"`))
	testing.expect(
		t,
		!strings.contains(output, `"label":"helper"`),
		"a local rule of another namespace must not be offered",
	)
}

@(test)
test_lsp_definition_skips_a_non_exported_member :: proc(t: ^testing.T) {
	dir := ns_setup(t, "cmd/lsp/testdata/scratch/definition_xns")
	defer os.remove_all("cmd/lsp/testdata/scratch/definition_xns")
	defer delete(dir)

	base_dir := strings.concatenate({dir, "/base"})
	defer delete(base_dir)
	os.make_directory_all(base_dir)
	rgram := strings.concatenate({base_dir, "/r.grammar"})
	defer delete(rgram)
	if err := os.write_entire_file(rgram, "helper = \"x\";\n"); err != nil {
		testing.fail_now(t, "failed to write the imported namespace")
	}

	a_uri := strings.concatenate({"file://", dir, "/a.grammar"})
	defer delete(a_uri)
	a_open := doc_params(
		a_uri,
		`,"languageId":"grammar","version":1,"text":"ns = @import(\"./base\");\nexpr = ns.helper;"}}`,
	)
	defer delete(a_open)
	// Definition on `helper` in `ns.helper` (line 1, character 11).
	a_pos := doc_params(a_uri, `},"position":{"line":1,"character":11}}`)
	defer delete(a_pos)

	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(`textDocument/didOpen`, a_open),
		make_request(`2`, `textDocument/definition`, a_pos),
		make_request(`3`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	log.debugf("output:\n%v", output)
	def := response_for(output, `2`)
	testing.expect(
		t,
		!strings.contains(def, "r.grammar"),
		"a local rule of another namespace has no definition to jump to",
	)
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
test_lsp_signature_help :: proc(t: ^testing.T) {
	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(
			`textDocument/didOpen`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar","languageId":"grammar","version":1,"text":"greet name title = \"hello\" name title;\ngreeting = \"hi\";\nmain = <greet greeting greeting>;"}}`,
		),
		// Signature help on the proc name inside the call (line 2, character 8).
		make_request(
			`2`,
			`textDocument/signatureHelp`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar"},"position":{"line":2,"character":8}}`,
		),
		// Signature help while editing the second argument (character 24).
		make_request(
			`3`,
			`textDocument/signatureHelp`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar"},"position":{"line":2,"character":24}}`,
		),
		// Signature help on a production's rule name (line 1, character 3).
		make_request(
			`4`,
			`textDocument/signatureHelp`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar"},"position":{"line":1,"character":3}}`,
		),
		make_request(`5`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	log.debugf("output:\n%v", output)
	testing.expect(t, strings.contains(output, `"kind":"markdown"`))
	testing.expect(t, strings.contains(output, "**type:** proc, 2 parameters, returns a production"))

	// Every assertion below is scoped to a single response line. Asserting against the
	// whole stream cannot tell a right answer from a right answer to some other request,
	// which is what let a call's signature leak onto positions that hold no call.
	on_callee := response_for(output, `2`)
	testing.expect(t, strings.contains(on_callee, `"label":"greet(name, title)"`))
	testing.expect(t, strings.contains(on_callee, `"label":"name"`))
	testing.expect(t, strings.contains(on_callee, `"label":"title"`))

	second_arg := response_for(output, `3`)
	testing.expect(t, strings.contains(second_arg, `"activeParameter":1`))

	// The call sits on the last line here, so this position precedes it. Asserting that
	// the answer does not name the call's callee is the point of the request.
	on_rule := response_for(output, `4`)
	testing.expect(t, strings.contains(on_rule, `"label":"greeting"`))
	testing.expect(t, strings.contains(on_rule, "**type:** production, returns a production"))
	testing.expect(
		t,
		!strings.contains(on_rule, `"label":"greet(`),
		"a position outside the call must not be described as one of its arguments",
	)
}

@(test)
test_lsp_signature_help_after_call :: proc(t: ^testing.T) {
	// A grammar whose first call is followed by more text. A call's span used to run to
	// the end of the file, so every position from the first call onwards was described
	// by it, and the first call here has one argument, which read as the arity-1 proc.
	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(
			`textDocument/didOpen`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar","languageId":"grammar","version":1,"text":"Source = { decl };\n\ndecl = let\n     | var\n     | const\n     ;\n\nlet   = <def \"let\">;\nvar   = <def \"var\">;\nconst = <def \"const\">;\n\ndef     k = <def k expr>;\ndef   k e = <def k ident e>;\ndef k i e = k i \"=\" e \";\"\n          | k i \";\"\n          ;\n\nident = __ident__;\nexpr  = __expr__;"}}`,
		),
		// Inside `<def k expr>` (line 11), on the callee.
		make_request(
			`2`,
			`textDocument/signatureHelp`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar"},"position":{"line":11,"character":15}}`,
		),
		// On the rule name `ident` (line 17), well past the last call.
		make_request(
			`3`,
			`textDocument/signatureHelp`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar"},"position":{"line":17,"character":1}}`,
		),
		// On the external value `__ident__` (line 17).
		make_request(
			`4`,
			`textDocument/signatureHelp`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar"},"position":{"line":17,"character":10}}`,
		),
		// On the declaration `def   k e` (line 12), which is a proc of arity two.
		make_request(
			`5`,
			`textDocument/signatureHelp`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar"},"position":{"line":12,"character":1}}`,
		),
		make_request(`6`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	log.debugf("output:\n%v", output)

	// The call passes two arguments, so the second overload is the active one.
	on_call := response_for(output, `2`)
	testing.expect(t, strings.contains(on_call, `"activeSignature":1`))
	testing.expect(t, strings.contains(on_call, `"label":"def(k, e)"`))

	// All three overloads are offered, ordered by arity so the list does not depend on
	// the order the file declares them in.
	arity_1 := strings.index(on_call, `"label":"def(k)"`)
	arity_2 := strings.index(on_call, `"label":"def(k, e)"`)
	arity_3 := strings.index(on_call, `"label":"def(k, i, e)"`)
	testing.expect(t, arity_1 >= 0)
	testing.expect(t, arity_2 >= 0)
	testing.expect(t, arity_3 >= 0)
	testing.expect(t, arity_1 < arity_2, "overloads must be offered in ascending arity")
	testing.expect(t, arity_2 < arity_3, "overloads must be offered in ascending arity")

	// Neither of these positions is inside a call, so neither may name one.
	on_rule := response_for(output, `3`)
	testing.expect(t, strings.contains(on_rule, `"label":"ident"`))
	testing.expect(t, strings.contains(on_rule, "**type:** production, returns a production"))
	testing.expect(t, !strings.contains(on_rule, "def"), "a rule name past a call must not report a call")

	on_external := response_for(output, `4`)
	testing.expect(t, strings.contains(on_external, "**type:** external value"))
	testing.expect(t, !strings.contains(on_external, "def"), "an external value must not report a call")

	// A proc's own declaration resolves at the arity it is declared at.
	on_declaration := response_for(output, `5`)
	testing.expect(t, strings.contains(on_declaration, `"activeSignature":1`))
	testing.expect(t, strings.contains(on_declaration, `"label":"def(k, e)"`))
}

@(test)
test_lsp_signature_help_call_extent :: proc(t: ^testing.T) {
	// The three shapes a call's extent has to get right: a `>` inside a quoted argument
	// does not close the call, and the innermost call of a nested one is the one under
	// the cursor. `def` is declared at arities five, one and two so that ordering the
	// overloads by arity is observable.
	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(
			`textDocument/didOpen`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar","languageId":"grammar","version":1,"text":"def k a b c d e = <def k>;\ndef k = <f \"a>b\">;\ndef k a = <f <g k a>>;\n\nf x = x;\ng x y = x y;"}}`,
		),
		// On `def` in `<def k>` (line 0): a one-argument call to `def`.
		make_request(
			`2`,
			`textDocument/signatureHelp`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar"},"position":{"line":0,"character":20}}`,
		),
		// On `f` in `<f <g k a>>` (line 2), the outer call.
		make_request(
			`3`,
			`textDocument/signatureHelp`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar"},"position":{"line":2,"character":11}}`,
		),
		// On `g` in the same call (line 2), the inner one.
		make_request(
			`4`,
			`textDocument/signatureHelp`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar"},"position":{"line":2,"character":14}}`,
		),
		// On the `>` that really closes `<f "a>b">` (line 1).
		make_request(
			`5`,
			`textDocument/signatureHelp`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar"},"position":{"line":1,"character":16}}`,
		),
		make_request(`6`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	log.debugf("output:\n%v", output)

	// `def` is declared at arities five, one and two in that order, so an ascending list
	// puts the arity-one overload first and marks it active.
	on_call := response_for(output, `2`)
	testing.expect(t, strings.contains(on_call, `"activeSignature":0`))
	testing.expect(t, strings.contains(on_call, `"label":"def(k)"`))

	on_outer := response_for(output, `3`)
	testing.expect(t, strings.contains(on_outer, `"label":"f(x)"`))
	testing.expect(t, !strings.contains(on_outer, `"label":"g(`), "the outer call wins at its own callee")

	on_inner := response_for(output, `4`)
	testing.expect(t, strings.contains(on_inner, `"label":"g(x, y)"`))
	testing.expect(t, !strings.contains(on_inner, `"label":"f(`), "the inner call wins at its own callee")

	// The `>` inside the quoted argument must not be read as the end of the call.
	on_closing_angle := response_for(output, `5`)
	testing.expect(t, strings.contains(on_closing_angle, `"label":"f(x)"`))
	testing.expect(t, !strings.contains(on_closing_angle, "def"))
}

@(test)
test_lsp_signature_help_nearest_overload :: proc(t: ^testing.T) {
	// The call passes an arity no overload of `def` declares, which the checker reports.
	// The nearest declared arity is then the active one, and the distances are 1, 2 and
	// 3 so that the first signature is the closest.
	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(
			`textDocument/didOpen`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar","languageId":"grammar","version":1,"text":"def k = k;\ndef k a b c = k a b c;\ndef k a b c d e = k a b c d e;\na = \"a\";\nmain = <def k a>;"}}`,
		),
		// On `def` in `<def k a>` (line 4): two arguments, and no proc of two.
		make_request(
			`2`,
			`textDocument/signatureHelp`,
			`{"textDocument":{"uri":"file:///tmp/test.grammar"},"position":{"line":4,"character":9}}`,
		),
		make_request(`3`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	log.debugf("output:\n%v", output)

	on_call := response_for(output, `2`)
	testing.expect(t, strings.contains(on_call, `"label":"def(k)"`))
	testing.expect(t, strings.contains(on_call, `"activeSignature":0`))
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

// A tag is one token that names nothing, so it contributes no semantic token:
// the same file with and without a tag highlights the same number of tokens. Only
// the columns after it move, since it takes up source text.
@(test)
test_lsp_semantic_tokens_skip_a_tag :: proc(t: ^testing.T) {
	plain := semantic_token_data(t, "tag_plain.grammar", `expr = term;\nterm = \"a\";`)
	defer delete(plain)
	tagged := semantic_token_data(t, "tag_tagged.grammar", `expr = term `+"`"+`name=\"a\"`+"`"+`;\nterm = \"a\";`)
	defer delete(tagged)

	testing.expect(t, len(plain) > 0, "expected semantic tokens for the plain file")
	// Each token is five numbers: line delta, column delta, length, type, mods.
	testing.expectf(
		t,
		strings.count(plain, ",") == strings.count(tagged, ","),
		"a tag should add no semantic tokens: %d entries with it, %d without",
		strings.count(tagged, ",") + 1,
		strings.count(plain, ",") + 1,
	)
}

// semantic_token_data opens a document whose text is the JSON escaped text under
// the given name, asks for its full semantic tokens and returns the encoded data
// array. The caller must delete the result.
semantic_token_data :: proc(t: ^testing.T, name, json_text: string) -> string {
	uri := strings.concatenate({"file:///tmp/", name})
	defer delete(uri)
	did_open := strings.concatenate(
		{
			`{"textDocument":{"uri":"`,
			uri,
			`","languageId":"grammar","version":1,"text":"`,
			json_text,
			`"}}`,
		},
	)
	defer delete(did_open)
	params := strings.concatenate({`{"textDocument":{"uri":"`, uri, `"}}`})
	defer delete(params)

	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{"textDocument":{"semanticTokens":{}}}}`,
		),
		make_notification(`textDocument/didOpen`, did_open),
		make_request(`2`, `textDocument/semanticTokens/full`, params),
		make_request(`3`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	log.debugf("output:\n%v", output)

	start := strings.index(output, `"data":[`)
	if start < 0 {
		testing.expectf(t, false, "no semantic tokens for %s", name)
		return ""
	}
	start += len(`"data":[`)
	end := strings.index(output[start:], `]`)
	if end < 0 {
		testing.expectf(t, false, "unterminated semantic tokens for %s", name)
		return ""
	}
	return strings.clone(output[start:start + end])
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

// doc_params builds a textDocument parameter object for uri, with rest appended
// to close the uri value and supply the remaining members. The result is owned
// by the caller.
doc_params :: proc(uri, rest: string) -> string {
	return strings.concatenate({`{"textDocument":{"uri":"`, uri, `"`, rest})
}

// response_for returns the single response line carrying the given request id,
// or "" when the server wrote no such response. Notifications that share the
// output stream (diagnostics, logs) are ignored, so a test can assert on one
// response without tripping over the others. The result aliases `output` and
// must not be deleted.
response_for :: proc(output, id: string) -> string {
	lines := strings.split_lines(output)
	defer delete(lines)
	prefix := strings.concatenate({`{"jsonrpc": "2.0", "id": `, id}, context.temp_allocator)
	for line in lines {
		if strings.has_prefix(line, prefix) {
			return line
		}
	}
	return ""
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
	// These two builders buffer an entire session, so they outlive the
	// per-message temp-allocator guard the server installs in handle_message.
	// Backing them with context.temp_allocator corrupts the run: the guard
	// reclaims and zeroes memory above its mark as these builders grow, and
	// growth happens while the server is streaming responses into sb_out. Use
	// the heap allocator and free the buffers here instead.
	//
	// stdin is safe to leave on temp_allocator: it is built before run starts,
	// so it sits below every guard mark and is never reclaimed.
	sb_log := strings.builder_make(context.allocator)
	sb_out := strings.builder_make(context.allocator)
	defer delete_string(strings.to_string(sb_log), context.allocator)
	defer delete_string(strings.to_string(sb_out), context.allocator)

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

// A proc of a name is one of several, and the arity is what tells them apart, so a
// hover names it `proc: name/arity` rather than repeating the name. The source shown
// is the declaration of that arity and not of its siblings.
@(test)
test_lsp_hover_names_a_proc_by_its_arity :: proc(t: ^testing.T) {
	uri := `file:///tmp/proc.grammar`
	open := doc_params(
		uri,
		`,"languageId":"grammar","version":1,"text":"p x = x;\np x y = x y;\nq = <p \"a\" \"b\">;"}}`,
	)
	defer delete(open)
	decl := doc_params(uri, `},"position":{"line":1,"character":0}}`)
	defer delete(decl)

	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(`textDocument/didOpen`, open),
		make_request(`2`, `textDocument/hover`, decl),
		make_request(`3`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	hover := response_for(output, `2`)
	testing.expectf(t, strings.contains(hover, "proc: p/2"), "got %s", hover)
	testing.expectf(t, strings.contains(hover, `p x y = x y;`), "got %s", hover)
	// The arity-1 declaration is a different declaration and is not the one shown.
	testing.expectf(t, !strings.contains(hover, "p x = x;"), "got %s", hover)
}

// A call resolves to the proc of the arity it passes, so hovering the callee shows
// that overload's source rather than the one of another arity.
@(test)
test_lsp_hover_on_a_call_shows_the_resolved_overload :: proc(t: ^testing.T) {
	uri := `file:///tmp/overload.grammar`
	open := doc_params(
		uri,
		`,"languageId":"grammar","version":1,"text":"p x = x;\np x y = x y;\nq = <p \"a\" \"b\">;"}}`,
	)
	defer delete(open)
	// Character 5 is the `p` of the call; 6 is the space and 7 opens the first
	// argument's string.
	callee := doc_params(uri, `},"position":{"line":2,"character":5}}`)
	defer delete(callee)

	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(`textDocument/didOpen`, open),
		make_request(`2`, `textDocument/hover`, callee),
		make_request(`3`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	hover := response_for(output, `2`)
	testing.expectf(t, strings.contains(hover, "proc: p/2"), "got %s", hover)
	testing.expectf(t, strings.contains(hover, `p x y = x y;`), "got %s", hover)
	testing.expectf(t, !strings.contains(hover, "p x = x;"), "got %s", hover)
}

// A name may be declared in a sibling file of the namespace, and a hover shows the
// source of the file that declares it rather than the one being hovered.
@(test)
test_lsp_hover_shows_a_sibling_files_declaration :: proc(t: ^testing.T) {
	dir := ns_setup(t, "cmd/lsp/testdata/scratch/hover_sibling")
	defer os.remove_all("cmd/lsp/testdata/scratch/hover_sibling")
	defer delete(dir)

	sib := strings.concatenate({dir, "/sib.grammar"})
	defer delete(sib)
	if err := os.write_entire_file(sib, "helper = \"h\";\n"); err != nil {
		testing.fail_now(t, "failed to write sibling grammar")
	}

	sib_uri := strings.concatenate({"file://", sib})
	defer delete(sib_uri)
	sib_open := doc_params(
		sib_uri,
		`,"languageId":"grammar","version":1,"text":"helper = \"h\";"}}`,
	)
	defer delete(sib_open)

	main_uri := strings.concatenate({"file://", dir, "/main.grammar"})
	defer delete(main_uri)
	main_open := doc_params(
		main_uri,
		`,"languageId":"grammar","version":1,"text":"use = helper;"}}`,
	)
	defer delete(main_open)
	use := doc_params(main_uri, `},"position":{"line":0,"character":7}}`)
	defer delete(use)

	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(`textDocument/didOpen`, sib_open),
		make_notification(`textDocument/didOpen`, main_open),
		make_request(`2`, `textDocument/hover`, use),
		make_request(`3`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	hover := response_for(output, `2`)
	testing.expectf(t, strings.contains(hover, "rule: helper"), "got %s", hover)
	// The location names the file that declares it, which is not the one hovered.
	testing.expectf(t, strings.contains(hover, "sib.grammar"), "got %s", hover)
	testing.expectf(t, strings.contains(hover, `helper = \"h\";`), "got %s", hover)
}

// A proc's own name is its declaration, so references on it are the references of that
// proc: the declaration and the calls of that arity. Asking for them used to return
// nothing, because the request was resolved as if the name named the arity-zero rule of
// it, which a proc has not got.
@(test)
test_lsp_references_from_a_proc_declaration :: proc(t: ^testing.T) {
	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(
			`textDocument/didOpen`,
			`{"textDocument":{"uri":"file:///tmp/proc_ref.grammar","languageId":"grammar","version":1,"text":"foo = <group \"a\" \"b\">;\n\ngroup x y = x y;\n"}}`,
		),
		// On `group` of the declaration, which is the third line of the file and so
		// index 2, character 0. The blank line before it is line 1.
		make_request(
			`2`,
			`textDocument/references`,
			`{"textDocument":{"uri":"file:///tmp/proc_ref.grammar"},"position":{"line":2,"character":0},"context":{"includeDeclaration":true}}`,
		),
		make_request(`3`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	refs := response_for(output, `2`)
	// The declaration itself, and the call that reaches it.
	testing.expectf(t, strings.contains(refs, `"line":2,"character":0`), "got %s", refs)
	// The callee of `<group \"a\" \"b\">` begins at character 7; 6 is the `<`.
	testing.expectf(t, strings.contains(refs, `"line":0,"character":7`), "got %s", refs)
	testing.expectf(t, strings.count(refs, `"uri"`) == 2, "got %s", refs)
}

// The two ends of a symbol agree: the references of a call are the references of the
// declaration it reaches. Asking from either side returned the same set before a proc's
// own name was resolved by its arity, so this is the property that was broken.
@(test)
test_lsp_references_agree_from_either_end :: proc(t: ^testing.T) {
	uri := `file:///tmp/agree.grammar`
	src := `,"languageId":"grammar","version":1,"text":"foo = <group \"a\" \"b\">;\ngroup x y = x y;\n"}}`
	open := doc_params(uri, src)
	defer delete(open)
	from_decl := doc_params(
		uri,
		`},"position":{"line":1,"character":0},"context":{"includeDeclaration":true}}`,
	)
	defer delete(from_decl)
	from_call := doc_params(
		uri,
		`},"position":{"line":0,"character":7},"context":{"includeDeclaration":true}}`,
	)
	defer delete(from_call)

	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(`textDocument/didOpen`, open),
		make_request(`2`, `textDocument/references`, from_decl),
		make_request(`3`, `textDocument/references`, from_call),
		make_request(`4`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	decl_side := response_for(output, `2`)
	call_side := response_for(output, `3`)
	testing.expectf(t, strings.count(decl_side, `"uri"`) == 2, "got %s", decl_side)
	testing.expectf(t, strings.count(call_side, `"uri"`) == 2, "got %s", call_side)

	// The two responses differ only in their id, so the results are compared.
	decl_result := decl_side[strings.index(decl_side, `"result":`):]
	call_result := call_side[strings.index(call_side, `"result":`):]
	testing.expectf(
		t,
		decl_result == call_result,
		"from the declaration: %s\nfrom the call: %s",
		decl_result,
		call_result,
	)
}

// The procs of a name are separate declarations, so the references of one arity are
// not those of another: a call of a different arity does not name it.
@(test)
test_lsp_references_of_one_arity_exclude_the_others :: proc(t: ^testing.T) {
	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(
			`textDocument/didOpen`,
			`{"textDocument":{"uri":"file:///tmp/arity_ref.grammar","languageId":"grammar","version":1,"text":"one = <group \"a\">;\ntwo = <group \"a\" \"b\">;\ngroup x = x;\ngroup x y = x y;\n"}}`,
		),
		// On `group` of the arity-2 declaration at line 3, character 0.
		make_request(
			`2`,
			`textDocument/references`,
			`{"textDocument":{"uri":"file:///tmp/arity_ref.grammar"},"position":{"line":3,"character":0},"context":{"includeDeclaration":true}}`,
		),
		make_request(`3`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	refs := response_for(output, `2`)
	// Its own declaration and the arity-2 call, whose callee begins at character 7.
	testing.expectf(t, strings.contains(refs, `"line":3,"character":0`), "got %s", refs)
	testing.expectf(t, strings.contains(refs, `"line":1,"character":7`), "got %s", refs)
	testing.expectf(t, strings.count(refs, `"uri"`) == 2, "got %s", refs)
	// The arity-1 declaration and the arity-1 call are a different declaration.
	testing.expectf(t, !strings.contains(refs, `"line":2,"character":0`), "got %s", refs)
	testing.expectf(t, !strings.contains(refs, `"line":0,"character":7`), "got %s", refs)
}

// The declaration a call reaches is found by its own arity, so jumping from a proc's
// name lands on that proc rather than looking for a rule of that name.
@(test)
test_lsp_definition_from_a_proc_declaration :: proc(t: ^testing.T) {
	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(
			`textDocument/didOpen`,
			`{"textDocument":{"uri":"file:///tmp/proc_def.grammar","languageId":"grammar","version":1,"text":"foo = <group \"a\" \"b\">;\n\ngroup x y = x y;\n"}}`,
		),
		// On `group` of the declaration, which is index 2, character 0.
		make_request(
			`2`,
			`textDocument/definition`,
			`{"textDocument":{"uri":"file:///tmp/proc_def.grammar"},"position":{"line":2,"character":0}}`,
		),
		make_request(`3`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	target := response_for(output, `2`)
	testing.expectf(t, strings.contains(target, `"line":2,"character":0`), "got %s", target)
}

// Highlighting follows the declaration under the cursor, so it is matched by name and
// arity like references rather than across the procs of the name.
@(test)
test_lsp_highlight_of_a_proc_declaration :: proc(t: ^testing.T) {
	stdin := create_stream_reader(
		make_request(
			`1`,
			`initialize`,
			`{"clientInfo":{"name": "test", "version": "0.1"},"capabilities":{}}`,
		),
		make_notification(
			`textDocument/didOpen`,
			`{"textDocument":{"uri":"file:///tmp/proc_hl.grammar","languageId":"grammar","version":1,"text":"one = <group \"a\">;\ntwo = <group \"a\" \"b\">;\ngroup x = x;\ngroup x y = x y;\n"}}`,
		),
		// On `group` of the arity-2 declaration at line 3, character 0.
		make_request(
			`2`,
			`textDocument/documentHighlight`,
			`{"textDocument":{"uri":"file:///tmp/proc_hl.grammar"},"position":{"line":3,"character":0}}`,
		),
		make_request(`3`, `shutdown`, `null`),
	)

	output := send_request(stdin)
	marks := response_for(output, `2`)
	testing.expectf(t, strings.contains(marks, `"line":3,"character":0`), "got %s", marks)
	testing.expectf(t, strings.contains(marks, `"line":1,"character":7`), "got %s", marks)
	// The arity-1 declaration is a different declaration and is not marked.
	testing.expectf(t, !strings.contains(marks, `"line":2,"character":0`), "got %s", marks)
}
