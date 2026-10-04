# Grammar - an Odin implementation of the grammar DSL tool.

default: build

# Build the `grammar` binary in the project root.
build:
	odin build . -out:build/grammar

# Build the `grammar` binary in the project root.
build_debug: clean
	odin build . -debug -out:build/grammar

# Run all tests in every package.
test:
	odin test . -all-packages -out:build/grammar

# Run the grammar tool. Pass arguments after a `--`, e.g. `just run -- check example/hello.grammar --file`.
run ARGS="":
	odin run . -- {{ARGS}}

# Remove build artifacts.
clean:
	rm -rf build
