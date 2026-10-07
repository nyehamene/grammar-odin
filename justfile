# Grammar - an Odin implementation of the grammar DSL tool.

default: build

# Build the `grammar` binary in the project root.
build:
	odin build . -out:build/grammar

# Build the `grammar` binary in the project root.
build_debug: clean
	odin build . -debug -out:build/grammar

# Run all tests in every package.
#
# The argument makes a leaked or badly freed allocation fail the test that made
# it, and name the line; it is on by default. Odin only prints them by default,
# which is how a chain of alternatives went on leaking two boxes per link
# through forty-nine tests without any of them complaining. Pass false to see
# the report without failing on it, e.g. `just test false`.
test FAIL_ON_BAD_MEMORY="true":
	odin test . -all-packages -out:build/grammar \
		-define:ODIN_TEST_FAIL_ON_BAD_MEMORY={{FAIL_ON_BAD_MEMORY}}

# Run the grammar tool. Pass arguments after a `--`, e.g. `just run -- check example/hello.grammar --file`.
run ARGS="":
	odin run . -- {{ARGS}}

# Remove build artifacts.
clean:
	rm -rf build
