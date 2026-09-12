package main

import "core:fmt"
import "core:io"
import "core:os"

import "log"

import "cmd/check"
import "cmd/help"
import "cmd/lsp"
import "cmd/print"
import "cmd/version"

main :: proc() {
	context.logger = log.Setup()
	args := os.args[1:]
	stdin := os.to_stream(os.stdin)
	stdout := os.to_stream(os.stdout)
	stderr := os.to_stream(os.stdout)

	exit_code := run(args, stdin, stdout, stderr)
	os.exit(exit_code)
}

// run dispatches the CLI command and returns the process exit code. Output and
// diagnostics are written to the provided writers so callers can capture them.
// A separate writer for the language server wire protocol will be added later.
run :: proc(args: []string, stdin: io.Reader, stdout, stderr: io.Writer) -> int {
	if len(args) == 0 {
		io.write_string(stderr, "error: missing command. Run 'grammar help' for usage.\n")
		return 1
	}

	if args[0] == "--help" || args[0] == "-h" {
		help.run(stdout)
		return 0
	}

	command := args[0]
	rest := args[1:]

	if text := help.text_for(command); text != "" && has_help_flag(rest) {
		io.write_string(stdout, text)
		return 0
	}

	switch command {
	case "help":
		help.run(stdout)

	case "fmt":
		if len(rest) == 0 {
			err := fmt.tprintf("error: '%s' requires a PATH argument\n", command)
			io.write_string(stderr, err)
			return 1
		}
		path := rest[0]
		if !check.is_valid_path(path) {
			err := fmt.tprintf(
				"error: invalid path '%s': must be a relative path inside the current working directory\n",
				path,
			)
			io.write_string(stderr, err)
			return 1
		}
		log.infof("command %s on path %s", command, path)
		io.write_string(stdout, fmt.tprintf("Formatting %s...\n", path))

	case "check":
		return check.run(rest, stdin, stdout, stderr)

	case "print":
		return print.run(rest, stdin, stdout, stderr)

	case "lsp":
		logout: io.Writer

		file, err := os.open("lsp_log.txt", {.Write, .Create, .Append})
		if err != nil {
			// sb := new(strings.Builder, context.temp_allocator)
			// strings.builder_init(sb, context.temp_allocator)
			// logout = strings.to_stream(sb)
			panic("failed to create log file")
		} else {
			logout = os.to_stream(file)
		}

		defer if file != nil {
			os.close(file)
		}

		return lsp.run(rest, stdin, logout, stdout, stderr)

	case "diff":
		io.write_string(stdout, "TBD\n")

	case "version":
		version.run(stdout)

	case:
		err := fmt.tprintf("error: unknown command '%s'. Run 'grammar help' for usage.\n", command)
		io.write_string(stderr, err)
		return 1
	}

	return 0
}

// has_help_flag reports whether args contains a help flag.
has_help_flag :: proc(args: []string) -> bool {
	for arg in args {
		if arg == "--help" || arg == "-h" {
			return true
		}
	}
	return false
}
