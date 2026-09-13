package lsp

import "core:io"
import "core:log"
import "core:strings"
import "core:testing"

@(test)
test_lsp :: proc(t: ^testing.T) {
	stdin := create_request_reader(
		`1`,
		`"initialize"`,
		`{"clientInfo":{"name": "test", "version": "0.1"}, "capabilities": {"textDocument": {"semanticTokens": {}}}}`,
	)
	exit_code := send_request(stdin)
	testing.expect(t, exit_code == 0)
}

send_request :: proc(stdin: io.Reader) -> int {
	sb := strings.builder_make(context.temp_allocator)
	stdout := strings.to_writer(&sb)
	stderr := stdout
	logout := stdout
	test_mode := true

	args := []string{"lsp"}
	exit_code := run(args, stdin, logout, stdout, stderr, test_mode)

	if strings.builder_len(sb) > 0 {
		output := strings.to_string(sb)
		log.debugf("\n%v\n", output)
	}

	return exit_code
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
