package check

import "core:bytes"
import "core:fmt"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../../ast"
import "../../token"

Mode :: enum {
	File,
	Package,
}

// run implements `grammar check`. It loads the target file (or all .grammar
// files in a directory) into a compilation unit and reports lexical, syntax
// and semantic errors. It returns 0 when everything is well-formed, and
// non-zero otherwise.
run :: proc(args: []string, stdin: io.Reader, stdout, stderr: io.Writer) -> int {
	path, mode, use_stdin, ok := parse_args(args)
	if !ok {
		io.write_string(stderr, "error: invalid arguments for 'grammar check'\n")
		return 1
	}

	if use_stdin {
		return check_reader(stdin, "<stdin>", stderr)
	}

	if path == "" {
		io.write_string(stderr, "error: 'check' requires a PATH argument\n")
		return 1
	}
	if !is_valid_path(path) {
		io.write_string(
			stderr,
			fmt.tprintf(
				"error: invalid path '%s': must be a relative path inside the current working directory\n",
				path,
			),
		)
		return 1
	}

	return check(path, mode, stderr)
}

// parse_args extracts the path argument, mode flag and --stdin flag.
parse_args :: proc(args: []string) -> (path: string, mode: Mode, use_stdin: bool, ok: bool) {
	mode = .Package
	for arg in args {
		switch arg {
		case "-f", "--file":
			mode = .File
		case "-p", "--package":
			mode = .Package
		case "--stdin":
			use_stdin = true
		case:
			if strings.has_prefix(arg, "-") || path != "" {
				return "", {}, false, false
			}
			path = arg
		}
	}
	return path, mode, use_stdin, true
}

// collect_files returns the grammar files for the given path and mode. In
// package mode a directory is walked recursively; a file path is returned
// directly.
collect_files :: proc(
	path: string,
	mode: Mode,
	allocator := context.allocator,
) -> (
	files: [dynamic]string,
) {
	files = make([dynamic]string, allocator)
	switch mode {
	case .File:
		append(&files, strings.clone(path, allocator))
	case .Package:
		// os.stat hands back a File_Info that owns its fullpath, so it has to be
		// released with file_info_delete or the path leaks on every call.
		info, stat_err := os.stat(path, allocator)
		defer os.file_info_delete(info, allocator)
		if stat_err == nil && info.type == .Directory {
			w := os.walker_create(path)
			defer os.walker_destroy(&w)
			for entry in os.walker_walk(&w) {
				if entry.type == .Regular && strings.has_suffix(entry.fullpath, ".grammar") {
					append(&files, strings.clone(entry.fullpath, allocator))
				}
			}
		} else {
			append(&files, strings.clone(path, allocator))
		}
	}
	return
}

// cleanup frees the strings in files and the array itself. allocator must be the
// one collect_files was given, since it owns those strings.
cleanup :: proc(files: [dynamic]string, allocator := context.allocator) {
	for f in files do delete(f, allocator)
	delete(files)
}

// check_reader scans a single source reader and reports errors on stderr.
check_reader :: proc(reader: io.Reader, name: string, stderr: io.Writer) -> int {
	data, ok := read_all(reader)
	if !ok {
		io.write_string(stderr, fmt.tprintf("error: could not read %s\n", name))
		return 1
	}
	defer delete(data)
	if check_source(string(data), name, stderr) do return 1
	return 0
}

// read_all reads from r until EOF and returns the bytes read.
read_all :: proc(r: io.Reader, allocator := context.allocator) -> (data: []byte, ok: bool) {
	buf: bytes.Buffer
	bytes.buffer_init(&buf, {})
	defer bytes.buffer_destroy(&buf)

	tmp := make([]byte, 8192, allocator)
	defer delete(tmp)

	for {
		n, err := io.read(r, tmp)
		if n > 0 {
			bytes.buffer_write(&buf, tmp[:n])
		}
		if err != nil {
			if err == .EOF do break
			return nil, false
		}
		if n == 0 do break
	}

	raw := bytes.buffer_to_bytes(&buf)
	data = make([]byte, len(raw), allocator)
	copy(data, raw)
	return data, true
}

// check_source scans and parses src, reporting any lexical and syntax errors.
// It returns true if an error was found.
check_source :: proc(src: string, name: string, stderr: io.Writer) -> bool {
	tokens, lex_errors := token.scan(src)
	defer delete(tokens)
	defer delete(lex_errors)

	file, parse_errors := ast.parse_file(src, tokens[:])
	defer ast.destroy_file(&file)
	defer delete(parse_errors)

	failed := false
	for e in lex_errors {
		pos := token.position_at(src, e.offset)
		io.write_string(
			stderr,
			fmt.tprintf("%s:%d:%d: %s\n", name, pos.line, pos.column, e.message),
		)
		failed = true
	}
	for e in parse_errors {
		pos := token.position_at(src, e.offset)
		io.write_string(
			stderr,
			fmt.tprintf("%s:%d:%d: %s\n", name, pos.line, pos.column, e.message),
		)
		failed = true
	}
	return failed
}

// is_valid_path reports whether path is a relative path that stays within the
// current working directory.
is_valid_path :: proc(path: string) -> bool {
	if filepath.is_abs(path) do return false

	cleaned, err := filepath.clean(path)
	if err != nil do return false
	if cleaned == "" || cleaned == "." do return false

	defer delete(cleaned)
	parts := strings.split(cleaned, filepath.SEPARATOR_STRING)
	defer delete(parts)

	for component in parts {
		if component == ".." do return false
	}
	return true
}
