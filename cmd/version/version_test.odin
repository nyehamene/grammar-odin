package version

import "core:bytes"
import "core:testing"

@(test)
test_version_constant :: proc(t: ^testing.T) {
	testing.expect(t, VERSION == "0.1.0", "version constant should be 0.1.0")
}

@(test)
test_run_writes_to_writer :: proc(t: ^testing.T) {
	buf: bytes.Buffer
	bytes.buffer_init(&buf, {})
	defer bytes.buffer_destroy(&buf)

	run(bytes.buffer_to_stream(&buf))

	testing.expect(t, bytes.buffer_to_string(&buf) == "0.1.0\n", "run should write the version followed by a newline")
}