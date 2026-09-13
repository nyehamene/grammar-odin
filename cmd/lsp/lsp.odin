package lsp

import "core:encoding/json"
import "core:io"

run :: proc(
	args: []string,
	stdin: io.Reader,
	logout, stdout, stderr: io.Writer,
	test_mode := false,
) -> int {
	debugf(logout, "starting lsp server")
	defer debugf(logout, "stopping lsp server")

	srv := &Server{}
	Server_init(srv, stdin, logout, stdout, stderr, test_mode)
	defer Server_destroy(srv)

	exit_code := 1

	frame := &Frame{}
	Frame_init(frame, stdin, logout)
	defer Frame_destroy(frame)

	for {
		// Each frame is read with its own freshly initialized headers map:
		// Frame_destroy frees the arena backing the map, so the map must be
		// re-created before the next frame is read.
		Frame_destroy(frame)
		Frame_init(frame, stdin, logout)

		buf, ok := read_frame(frame)
		if !ok {
			debugf(srv, "failed to read frame")
			exit_code = 0 if srv.test_mode || srv.shutdown_requested else 1
			break
		}

		debug(srv, string(buf))

		msg, err := json.parse(buf)
		if err != nil {
			debugf(srv, "failed to parse json: %v", string(buf))
			json.destroy_value(msg)
			continue
		}

		running := handle_message(srv, msg)
		json.destroy_value(msg)

		if !running {
			exit_code = 0 if srv.shutdown_requested else 1
			break
		}
	}

	return exit_code
}
