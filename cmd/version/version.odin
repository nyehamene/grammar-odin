package version

import "core:io"

VERSION :: "0.1.0"

// version returns the current version string.
version :: proc() -> string {
	return VERSION
}

// run writes the version to the given writer.
run :: proc(writer: io.Writer) {
	io.write_string(writer, version())
	io.write_byte(writer, '\n')
}