package version

import "core:testing"

@(test)
test_version_constant :: proc(t: ^testing.T) {
	testing.expect(t, VERSION == "0.1.0", "version constant should be 0.1.0")
}