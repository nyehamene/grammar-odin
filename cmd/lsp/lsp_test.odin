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
	testing.expect(t, strings.contains(output, "**`greeting`**"))
	testing.expect(t, strings.contains(output, "**type:** production, returns a production"))
	testing.expect(t, strings.contains(output, "declared at"))
	testing.expect(t, strings.contains(output, "1:1"))
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
	testing.expect(t, strings.contains(output, `**` + "`term`" + `**`))
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
	testing.expect(t, strings.contains(hover, "**`_item`**"))
	testing.expect(t, strings.contains(hover, "**declared at:** `1:1`"))

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
	testing.expect(t, strings.contains(output, `"id": 2`))
	testing.expect(t, strings.contains(output, `"kind":"markdown"`))
	testing.expect(t, strings.contains(output, `"label":"greet(name, title)"`))
	testing.expect(t, strings.contains(output, `"label":"name"`))
	testing.expect(t, strings.contains(output, `"label":"title"`))
	testing.expect(t, strings.contains(output, "**type:** proc, 2 parameters, returns a production"))
	testing.expect(t, strings.contains(output, `"id": 3`))
	testing.expect(t, strings.contains(output, `"activeParameter":1`))
	testing.expect(t, strings.contains(output, `"id": 4`))
	testing.expect(t, strings.contains(output, `"label":"greeting"`))
	testing.expect(t, strings.contains(output, "**type:** production, returns a production"))
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
