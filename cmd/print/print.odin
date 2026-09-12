package printcmd

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"

import "../../ast"
import "../../token"
import "../check"

// run implements `grammar print`. Unless -t/--token is given the AST of each
// file is printed; directories are expanded to their grammar files. On error
// the partial output is printed and diagnostics are written to stderr, with a
// non-zero exit code.
run :: proc(args: []string, stdin: io.Reader, stdout, stderr: io.Writer) -> int {
	show_tokens, show_ast, path, ok := parse_args(args)
	if !ok {
		io.write_string(stderr, "error: invalid arguments for 'grammar print'\n")
		return 1
	}
	if !show_tokens && !show_ast {
		show_ast = true
	}
	if path == "" {
		io.write_string(stderr, "error: 'print' requires a PATH argument\n")
		return 1
	}
	if !check.is_valid_path(path) {
		io.write_string(stderr, fmt.tprintf("error: invalid path '%s': must be a relative path inside the current working directory\n", path))
		return 1
	}

	files := check.collect_files(path, check.Mode.Package)
	defer check.cleanup(files)

	failed := false
	for file in files {
		data, err := os.read_entire_file_from_path(file, context.allocator)
		if err != nil {
			io.write_string(stderr, fmt.tprintf("error: could not read '%s'\n", file))
			failed = true
			continue
		}
		src := string(data)

		io.write_string(stdout, fmt.tprintf("== %s ==\n", file))
		code := 0
		if show_tokens {
			code = print_tokens(src, file, stdout, stderr)
		} else {
			code = print_ast(src, file, stdout, stderr)
		}
		if code != 0 {
			failed = true
		}
		delete(data)
	}

	if failed {
		return 1
	}
	return 0
}

// parse_args extracts the -t/--token and -a/--ast flags and the path argument.
parse_args :: proc(args: []string) -> (show_tokens, show_ast: bool, path: string, ok: bool) {
	for arg in args {
		switch arg {
		case "-t", "--token":
			show_tokens = true
		case "-a", "--ast":
			show_ast = true
		case:
			if strings.has_prefix(arg, "-") || path != "" {
				return false, false, "", false
			}
			path = arg
		}
	}
	return show_tokens, show_ast, path, true
}

// print_tokens writes the token table for src and reports any lexical errors.
print_tokens :: proc(src, name: string, stdout, stderr: io.Writer) -> int {
	tokens, lex_errors := token.scan(src)
	defer delete(tokens)
	defer delete(lex_errors)

	io.write_string(stdout, fmt.tprintf("%-10s %-15s %s\n", "Line:Col", "KIND", "LEXEME"))
	io.write_string(stdout, "--------------------------------------------------\n")
	for tok in tokens {
		pos := token.position_at(src, tok.start)
		line_col := fmt.tprintf("%d:%d", pos.line, pos.column)
		io.write_string(stdout, fmt.tprintf("%-10s %-15s ", line_col, token.kind_name(tok.kind)))
		if tok.kind == .String {
			io.write_string(stdout, token.lexeme(tok, src))
		} else {
			token.write_lexeme(stdout, token.lexeme(tok, src))
		}
		io.write_string(stdout, "\n")
	}

	return report_errors(src, name, lex_errors[:], nil, stderr)
}

// print_ast writes the AST tree for src and reports any lexical or syntax
// errors.
print_ast :: proc(src, name: string, stdout, stderr: io.Writer) -> int {
	tokens, lex_errors := token.scan(src)
	defer delete(tokens)
	defer delete(lex_errors)

	file, parse_errors := ast.parse_file(src, tokens[:])
	defer ast.destroy_file(&file)
	defer delete(parse_errors)

	ast.print_file(stdout, src, &file)

	return report_errors(src, name, lex_errors[:], parse_errors[:], stderr)
}

// report_errors prints lexical and parse diagnostics to stderr in the form
// `name:line:col: message`. It returns 1 if any error was reported.
report_errors :: proc(src, name: string, lex_errors: []token.Error, parse_errors: []ast.Error, stderr: io.Writer) -> int {
	failed := 0
	for e in lex_errors {
		pos := token.position_at(src, e.offset)
		io.write_string(stderr, fmt.tprintf("%s:%d:%d: %s\n", name, pos.line, pos.column, e.message))
		failed = 1
	}
	for e in parse_errors {
		pos := token.position_at(src, e.offset)
		io.write_string(stderr, fmt.tprintf("%s:%d:%d: %s\n", name, pos.line, pos.column, e.message))
		failed = 1
	}
	return failed
}