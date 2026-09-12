package lsp_test

import ".."

main :: proc() {
	stdin := lsp.create_request_reader(
		`"1"`,
		`"initialize"`,
		// `{"clientInfo":{"name": "test", "version": "0.1"}, "capabilities": {"textDocument": {"semanticTokens": {}}}}`,
		"",
	)
	exit_code := lsp.send_request(stdin)
}
