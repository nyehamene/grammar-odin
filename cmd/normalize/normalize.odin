package normalizecmd

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"

import "../../ast"
import "../../token"
import "../astscope"
import "../check"

// run implements `grammar normalize`. Every rule of the target is expanded and then
// factored: each alternative in the body is split into the productions its branches
// share at the start, the productions they do not share, and the productions they
// share at the end. The result goes to stdout or back to the file it came from.
//
// A rule the scope cannot expand is written as it stands and reported on stderr,
// with a non-zero exit code, and so is one whose factored form holds a branch that
// the leading and the trailing matched on their own: written out it is `( | x )`,
// which does not parse.
run :: proc(args: []string, stdin: io.Reader, stdout, stderr: io.Writer) -> int {
	opts, ok, message := parse_args(args)
	if !ok {
		io.write_string(stderr, message)
		io.write_string(stderr, "error: invalid arguments for 'grammar normalize'\n")
		return 1
	}
	if opts.write_in_place && opts.as_tree {
		io.write_string(
			stderr,
			"error: '--write' and '--tree' cannot be combined: a tree is not source\n",
		)
		return 1
	}
	if opts.write_in_place && opts.has_at {
		io.write_string(
			stderr,
			"error: '--write' and '--select' cannot be combined: a selected declaration is written to stdout\n",
		)
		return 1
	}
	if opts.has_at && len(opts.at.file) > 0 && !check.is_valid_path(opts.at.file) {
		// The file of a selection is a path like any other, and a selection may reach
		// a file of a directory the path names.
		io.write_string(
			stderr,
			fmt.tprintf(
				"error: invalid path '%s': must be a relative path inside the current working directory\n",
				opts.at.file,
			),
		)
		return 1
	}
	if opts.has_at && opts.use_stdin {
		io.write_string(
			stderr,
			"error: '--select' names a position in a file, so it cannot be used with '--stdin'\n",
		)
		return 1
	}

	options := ast.Normalize_Options{tags = opts.tags}
	defer ast.destroy_normalize_options(&options)

	if opts.use_stdin {
		return normalize_reader(stdin, &options, opts.as_tree, stdout, stderr)
	}

	if opts.path == "" {
		io.write_string(stderr, "error: 'normalize' requires a PATH argument\n")
		return 1
	}
	if !check.is_valid_path(opts.path) {
		io.write_string(
			stderr,
			fmt.tprintf(
				"error: invalid path '%s': must be a relative path inside the current working directory\n",
				opts.path,
			),
		)
		return 1
	}

	packages := astscope.Load(opts.path, stderr)
	defer astscope.Destroy_All(packages)
	return transform_packages(
		packages[:],
		&options,
		opts.write_in_place,
		opts.as_tree,
		opts.at,
		opts.has_at,
		stdout,
		stderr,
	)
}

// normalize_reader normalizes the rules of a source read from a reader, against a
// scope of its own rules.
normalize_reader :: proc(
	reader: io.Reader,
	opts: ^ast.Normalize_Options,
	as_tree: bool,
	stdout, stderr: io.Writer,
) -> int {
	data, read_ok := astscope.Read_All(reader)
	if !read_ok {
		io.write_string(stderr, "error: could not read stdin\n")
		return 1
	}
	defer delete(data)

	packages := astscope.Load_Source(string(data), "<stdin>", stderr)
	defer astscope.Destroy_All(packages)
	if len(packages) == 0 do return 1
	return transform_packages(
		packages[:],
		opts,
		false,
		as_tree,
		token.Selection{},
		false,
		stdout,
		stderr,
	)
}

// transform_packages normalizes every rule of every file, printing each file's
// result under a heading unless it is being written back where it came from.
transform_packages :: proc(
	packages: []astscope.Package,
	opts: ^ast.Normalize_Options,
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
				opts,
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
		if len(at.file) > 0 {
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

// transform_file normalizes the rules of one file and writes the result. It returns
// non-zero when a rule could not be expanded, when a rule factored into something
// that will not parse back, or when the file could not be written.
//
// The output is collected first, so that --write replaces a file only once the
// whole thing has been produced.
transform_file :: proc(
	file: ^astscope.File,
	scope: ^ast.Scope,
	opts: ^ast.Normalize_Options,
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
			normalized, expanded_ok := ast.normalize_rule(it, scope, opts)
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
			if ast.Has_Empty_Middle(normalized) {
				io.write_string(
					stderr,
					fmt.tprintf(
						"%s: rule %s has a branch the leading and the trailing match on their own, so it is written as its branches\n",
						name,
						it.ident.name,
					),
				)
				failed = true
			}
			if as_tree {
				ast.Print_Normalized_Rule(stream, src, normalized)
			} else {
				ast.Write_Normalized_Rule(stream, normalized, width)
			}
			ast.destroy_normalized_rule(&normalized)
		case ast.Binding:
			ast.Write_Binding(stream, it)
		case ast.Comment_Group:
			ast.Write_Comment_Group(stream, it)
		}
	}

	report_conflicts(opts, name, stderr)

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

// report_conflicts writes the tag conflicts recorded since the last file, then
// drains them so that the next file reports only its own. A tag two branches give
// the same production differently is resolved by dropping one of them, which is what
// .Block does, and .Merge keeps the first value where a pair name cannot hold both.
// Either way the contradiction is said out loud rather than left to be noticed in
// the output.
report_conflicts :: proc(opts: ^ast.Normalize_Options, name: string, stderr: io.Writer) {
	for conflict in opts.conflicts[:] {
		io.write_string(
			stderr,
			fmt.tprintf(
				"%s: rule tags %s differ between alternatives: %s and %s\n",
				name,
				conflict.name,
				conflict.left,
				conflict.right,
			),
		)
	}
	ast.Clear_Conflicts(opts)
}

// Outcome is what transforming one file came to. A selection can leave a file alone
// when it names another one, or names a position no declaration of it covers.
Outcome :: enum {
	Done,
	Skipped,
	Failed,
}

// Options is what `grammar normalize` was asked to do.
Options :: struct {
	write_in_place: bool,
	as_tree:       bool,
	use_stdin:     bool,
	path:          string,
	tags:          ast.Tag_Policy,
	at:            token.Selection, // the position given to --select
	has_at:        bool,
}

// parse_args extracts the flags and the path in one pass. The tag policy is a value
// rather than a flag, so --tags takes one and an unknown one is named back.
parse_args :: proc(args: []string) -> (opts: Options, ok: bool, message: string) {
	opts.tags = .Strip
	// An index loop rather than a range loop, because the value of --tags has to
	// be stepped over rather than read as a path of its own.
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		switch arg {
		case "-w", "--write":
			opts.write_in_place = true
		case "--tree":
			opts.as_tree = true
		case "--stdin":
			opts.use_stdin = true
		case "--select":
			if i + 1 >= len(args) {
				return opts, false, "error: '--select' needs a line:column or file:line:column\n"
			}
			text := args[i + 1]
			i += 1
			// The shape is checked before anything is loaded, so that a malformed
			// selection is reported whatever the path turns out to be.
			selection, selection_ok := token.Parse_Selection(text)
			if !selection_ok {
				return opts, false, fmt.tprintf("error: '%s' is not a line:column or file:line:column\n", text)
			}
			opts.at = selection
			opts.has_at = true
		case "--tags":
			if i + 1 >= len(args) {
				return opts, false, "error: '--tags' needs a policy\n"
			}
			// The value is a policy rather than a path, so it is stepped over.
			i += 1
			policy := args[i]
			switch policy {
			case "strip":
				opts.tags = .Strip
			case "block":
				opts.tags = .Block
			case "merge":
				opts.tags = .Merge
			case "keep":
				opts.tags = .Keep
			case:
				return opts,
					false,
					fmt.tprintf(
						"error: unknown tag policy '%s': expected strip, block, merge or keep\n",
						policy,
					),
			}
		case:
			if strings.has_prefix(arg, "-") || opts.path != "" {
				return opts, false, ""
			}
			opts.path = arg
		}
	}
	return opts, true, ""
}
