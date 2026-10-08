package expandcmd

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"

import "../../ast"
import "../../token"
import "../astscope"
import "../check"

// run implements `grammar expand`. Every rule of the target has the calls in it
// replaced by the bodies of the rules they name, and the result goes to stdout or
// back to the file it came from.
//
// A rule the scope cannot expand is written as it stands and reported on stderr,
// with a non-zero exit code: the output is there to look at, and the exit code is
// there so that a script notices a call is still in it.
run :: proc(args: []string, stdin: io.Reader, stdout, stderr: io.Writer) -> int {
	write_in_place, as_tree, use_stdin: bool
	path: string
	at: token.Selection
	has_at: bool
	ok: bool
	message: string
	write_in_place, as_tree, use_stdin, path, at, has_at, ok, message = parse_args(args)
	if !ok {
		io.write_string(stderr, message)
		io.write_string(stderr, "error: invalid arguments for 'grammar expand'\n")
		return 1
	}
	if write_in_place && as_tree {
		io.write_string(
			stderr,
			"error: '--write' and '--tree' cannot be combined: a tree is not source\n",
		)
		return 1
	}
	if write_in_place && has_at {
		io.write_string(
			stderr,
			"error: '--write' and '--select' cannot be combined: a selected declaration is written to stdout\n",
		)
		return 1
	}
	if has_at && at.file != "" && !check.is_valid_path(at.file) {
		// The file of a selection is a path like any other, and a selection may reach
		// a file of a directory the path names.
		io.write_string(
			stderr,
			fmt.tprintf(
				"error: invalid path '%s': must be a relative path inside the current working directory\n",
				at.file,
			),
		)
		return 1
	}
	if has_at && use_stdin {
		io.write_string(
			stderr,
			"error: '--select' names a position in a file, so it cannot be used with '--stdin'\n",
		)
		return 1
	}

	if use_stdin {
		return expand_reader(stdin, as_tree, stdout, stderr)
	}

	if path == "" {
		io.write_string(stderr, "error: 'expand' requires a PATH argument\n")
		return 1
	}
	if !check.is_valid_path(path) {
		io.write_string(
			stderr,
			fmt.tprintf(
				"error: invalid path '%s': must be a relative path inside the current working directory\n",
				path,
			),
		)
		return 1
	}

	packages := astscope.Load(path, stderr)
	defer astscope.Destroy_All(packages)
	return transform_packages(
		packages[:],
		write_in_place,
		as_tree,
		at,
		has_at,
		stdout,
		stderr,
	)
}

// expand_reader expands the rules of a source read from a reader, against a scope
// of its own rules.
expand_reader :: proc(reader: io.Reader, as_tree: bool, stdout, stderr: io.Writer) -> int {
	data, read_ok := astscope.Read_All(reader)
	if !read_ok {
		io.write_string(stderr, "error: could not read stdin\n")
		return 1
	}
	defer delete(data)

	packages := astscope.Load_Source(string(data), "<stdin>", stderr)
	defer astscope.Destroy_All(packages)
	if len(packages) == 0 do return 1
	return transform_packages(packages[:], false, as_tree, token.Selection{}, false, stdout, stderr)
}

// transform_packages expands every rule of every file, printing each file's result
// under a heading unless it is being written back where it came from.
// Outcome is what transforming one file came to. A selection can leave a file alone
// when it names another one, or names a position no declaration of it covers.
Outcome :: enum {
	Done,
	Skipped,
	Failed,
}

transform_packages :: proc(
	packages: []astscope.Package,
	write_in_place, as_tree: bool,
	at: token.Selection,
	has_at: bool,
	stdout, stderr: io.Writer,
) -> int {
	failed := false
	selected := false
	for pkg, i in packages {
		for &file in astscope.Files(&packages[i]) {
			if !write_in_place && !has_at {
				io.write_string(stdout, fmt.tprintf("== %s ==\n", astscope.Display(&file)))
			}
			switch transform_file(
				&file,
				astscope.Scope(&packages[i]),
				as_tree,
				write_in_place,
				at,
				has_at,
				stdout,
				stderr,
			) {
			case .Done:
				selected = true
			case .Skipped:
			case .Failed:
				failed = true
			}
		}
	}
	if failed do return 1
	// A selection that named a file, or a position, and reached neither is a
	// mistake worth saying so about rather than reporting nothing at all.
	if has_at && !selected {
		if at.file != "" {
			io.write_string(
				stderr,
				fmt.tprintf("error: no file of the input matches '%s'\n", at.file),
			)
		} else {
			io.write_string(
				stderr,
				fmt.tprintf("error: no declaration of the input covers %d:%d\n", at.pos.line, at.pos.column),
			)
		}
		return 1
	}
	return 0
}

// transform_file expands the rules of one file and writes the result. It returns
// non-zero when a rule could not be expanded or the file could not be written.
//
// The output is collected first, so that --write replaces a file only once the
// whole thing has been produced and a failure part way through leaves it be.
transform_file :: proc(
	file: ^astscope.File,
	scope: ^ast.Scope,
	as_tree, write_in_place: bool,
	at: token.Selection,
	has_at: bool,
	stdout, stderr: io.Writer,
) -> Outcome {
	src := astscope.Source(file)
	tree := astscope.Tree(file)
	name := astscope.Display(file)

	// --select narrows the file to the one declaration the position falls in, and
	// that offset is only meaningful for this file's own source.
	selected := -1
	if has_at {
		if !astscope.Selects_File(name, at) do return .Skipped
		offset, off_ok := token.offset_at(src, at.pos)
		if !off_ok do return .Skipped
		index, found := ast.Decl_Index_At(tree, offset)
		if !found do return .Skipped
		selected = index
	}

	out: strings.Builder
	strings.builder_init(&out, context.allocator)
	defer strings.builder_destroy(&out)
	stream := strings.to_stream(&out)

	// The rules written together are lined up on the widest left hand side among them,
	// which the parsed tree already says since expansion carries a rule's name and
	// parameters through unchanged. --select writes one declaration, so it is written to
	// its own width rather than padded out to a column where nothing else appears.
	width := ast.Max_Lhs_Width(tree.decls[:])
	if selected >= 0 {
		width = ast.Lhs_Width(tree.decls[selected])
	}

	failed := false
	for decl, index in tree.decls {
		if selected >= 0 && index != selected {
			continue
		}
		switch it in decl {
		case ast.Rule:
			expanded, expanded_ok := ast.expand_rule(it, scope)
			if !expanded_ok {
				io.write_string(
					stderr,
					fmt.tprintf(
						"%s: not every call of rule %s could be expanded\n",
						name,
						it.ident.name,
					),
				)
				failed = true
			}
			if as_tree {
				ast.Print_Rule(stream, src, expanded)
			} else {
				ast.Write_Rule(stream, expanded, width)
			}
			ast.destroy_rule(&expanded)
		case ast.Binding:
			ast.Write_Binding(stream, it)
		case ast.Comment_Group:
			ast.Write_Comment_Group(stream, it)
		}
	}

	// to_string hands back a view of the builder's buffer, so the text is copied
	// before the builder is destroyed.
	text := strings.clone(strings.to_string(out))
	defer delete(text)

	if write_in_place {
		if werr := os.write_entire_file(name, text); werr != nil {
			io.write_string(stderr, fmt.tprintf("error: could not write '%s'\n", name))
			return .Failed
		}
		return failed ? .Failed : .Done
	}

	io.write_string(stdout, text)
	return failed ? .Failed : .Done
}

// parse_args extracts the flags and the path. The flags are independent of one
// another and of where the path sits, so --select may come before or after it.
parse_args :: proc(args: []string) -> (
	write_in_place, as_tree, use_stdin: bool,
	path: string,
	at: token.Selection,
	has_at: bool,
	ok: bool,
	message: string,
) {
	// An index loop rather than a range loop, because the position given to
	// --select is a value and has to be stepped over rather than read as a path.
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		switch arg {
		case "-w", "--write":
			write_in_place = true
		case "--tree":
			as_tree = true
		case "--stdin":
			use_stdin = true
		case "--select":
			if i + 1 >= len(args) {
				return false,
					false,
					false,
					"",
					token.Selection{},
					false,
					false,
					"error: '--select' needs a line:column or file:line:column\n"
			}
			text := args[i + 1]
			i += 1
			// The shape is checked here, so that a malformed selection is reported
			// whatever the path turns out to be.
			selection, selection_ok := token.Parse_Selection(text)
			if !selection_ok {
				return false,
					false,
					false,
					"",
					token.Selection{},
					false,
					false,
					fmt.tprintf(
						"error: '%s' is not a line:column or file:line:column\n",
						text,
					)
			}
			at = selection
			has_at = true
		case:
			if strings.has_prefix(arg, "-") || path != "" {
				return false, false, false, "", token.Selection{}, false, false, ""
			}
			path = arg
		}
	}
	return write_in_place, as_tree, use_stdin, path, at, has_at, true, ""
}
