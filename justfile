# Grammar - an Odin implementation of the grammar DSL tool.
#
# Pinned Odin toolchain: see ODIN_VERSION below. See `just check-odin`.
ODIN_VERSION := "dev-2026-08"

default: build

# Build the `grammar` binary in the project root.
build: check-odin
	odin build . -out:grammar

# Run all tests in every package.
test: check-odin
	odin test . -all-packages

# Run the grammar tool. Pass arguments after a `--`, e.g. `just run -- check example/hello.grammar --file`.
run ARGS="": check-odin
	odin run . -- {{ARGS}}

# Remove build artifacts.
clean:
	rm -f grammar

# Ensure the pinned Odin toolchain is being used.
check-odin:
	@if ! odin version | grep -q -- "version {{ODIN_VERSION}}:"; then \
		echo "error: expected odin {{ODIN_VERSION}}" >&2; \
		exit 1; \
	fi