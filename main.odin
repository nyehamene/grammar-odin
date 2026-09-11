package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "log"

main :: proc() {
	context.logger = log.Setup()
	os.exit(run(os.args[1:]))
}

// run dispatches the CLI command and returns the process exit code.
run :: proc(args: []string) -> int {
	if len(args) == 0 {
		fmt.eprintln("error: missing command. Run 'grammar help' for usage.")
		return 1
	}

	command := args[0]
	rest := args[1:]

	switch command {
	case "fmt", "check":
		if len(rest) == 0 {
			fmt.eprintf("error: '%s' requires a PATH argument\n", command)
			return 1
		}
		path := rest[0]
		if !is_valid_path(path) {
			fmt.eprintf("error: invalid path '%s': must be a relative path inside the current working directory\n", path)
			return 1
		}
		log.infof("command %s on path %s", command, path)
		if command == "fmt" {
			fmt.printf("Formatting %s...\n", path)
		} else {
			fmt.printf("Validating %s...\n", path)
		}
	case "print", "diff", "lsp":
		fmt.println("TBD")
	case "help", "version":
		fmt.println("TBD")
	case:
		fmt.eprintf("error: unknown command '%s'. Run 'grammar help' for usage.\n", command)
		return 1
	}

	return 0
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