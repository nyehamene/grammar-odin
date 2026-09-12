package version

import "core:fmt"

VERSION :: "0.1.0"

// version returns the current version string.
version :: proc() -> string {
	return VERSION
}

// run prints the version to stdout.
run :: proc() {
	fmt.println(version())
}