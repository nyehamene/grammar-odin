package main

import "core:fmt"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "log"

import "cmd/help"
import "cmd/version"

main :: proc() {
	context.logger = log.Setup()
	os.exit(run(os.args[1:], os.to_stream(os.stdout), os.to_stream(os.stderr)))
}

// run dispatches the CLI command and returns the process exit code. Output and
// diagnostics are written to the provided writers so callers can capture them.
// A separate writer for the language server wire protocol will be added later.
run :: proc(args: []string, stdout, stderr: io.Writer) -> int {
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
	case "fmt", "check":
		if len(rest) == 0 {
			err := fmt.tprintf("error: '%s' requires a PATH argument\n", command)
			io.write_string(stderr, err)
			return 1
		}
		path := rest[0]
		if !is_valid_path(path) {
			err := fmt.tprintf(
				"error: invalid path '%s': must be a relative path inside the current working directory\n",
				path,
			)
			io.write_string(stderr, err)
			return 1
		}
		log.infof("command %s on path %s", command, path)
		if command == "fmt" {
			io.write_string(stdout, fmt.tprintf("Formatting %s...\n", path))
		} else {
			io.write_string(stdout, fmt.tprintf("Validating %s...\n", path))
		}
	case "print", "diff", "lsp":
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

// is_valid_path reports whether path is a relative path that stays within the
// current working directory. Absolute paths and paths containing a parent
// directory ("..") component are rejected.
is_valid_path :: proc(path: string) -> bool {
	if filepath.is_abs(path) {
		return false
	}

	cleaned, err := filepath.clean(path)
	if err != nil {
		return false
	}
	if cleaned == "" || cleaned == "." {
		return false
	}

	for component in strings.split(cleaned, filepath.SEPARATOR_STRING) {
		if component == ".." {
			return false
		}
	}

	return true
}
