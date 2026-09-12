package check

import "core:bytes"
import "core:fmt"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../../token"

Mode :: enum {
	File,
	Package,
}

// run implements `grammar check`. It scans the tokens of the target file (or
// all .grammar files in a directory) and reports lexical errors. It returns 0
// when every checked file scans cleanly, and non-zero otherwise.
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
		io.write_string(stderr, fmt.tprintf("error: invalid path '%s': must be a relative path inside the current working directory\n", path))
		return 1
	}

	files := collect_files(path, mode)
	defer cleanup(files)

	failed := false
	for file in files {
		data, err := os.read_entire_file(file, context.allocator)
		if err != nil {
			io.write_string(stderr, fmt.tprintf("error: could not read '%s'\n", file))
			failed = true
			continue
		}
		if check_source(string(data), file, stderr) {
			failed = true
		}
		delete(data)
	}

	if failed {
		return 1
	}
	return 0
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

// collect_files returns the grammar files to check for the given path and mode.
// In package mode a directory is walked recursively; a file path is checked
// directly.
collect_files :: proc(path: string, mode: Mode, allocator := context.allocator) -> (files: [dynamic]string) {
	files = make([dynamic]string, allocator)
	switch mode {
	case .File:
		append(&files, strings.clone(path))
	case .Package:
		if info, err := os.stat(path, context.allocator); err == nil && info.type == .Directory {
			w := os.walker_create(path)
			defer os.walker_destroy(&w)
			for info in os.walker_walk(&w) {
				if info.type == .Regular && strings.has_suffix(info.fullpath, ".grammar") {
					append(&files, strings.clone(info.fullpath))
				}
			}
		} else {
			append(&files, strings.clone(path))
		}
	}
	return
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

// check_source scans src and reports any lexical errors. It returns true if an
// error was found.
check_source :: proc(src: string, name: string, stderr: io.Writer) -> bool {
	_, errors := token.scan(src)
	defer delete(errors)

	failed := false
	for e in errors {
		pos := token.position_at(src, e.offset)
		io.write_string(stderr, fmt.tprintf("%s:%d:%d: %s\n", name, pos.line, pos.column, e.message))
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

	for component in strings.split(cleaned, filepath.SEPARATOR_STRING) {
		if component == ".." do return false
	}
	return true
}

cleanup :: proc(files: [dynamic]string) {
	for f in files do delete(f)
	delete(files)
}