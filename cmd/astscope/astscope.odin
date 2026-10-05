// Package astscope loads grammar files into the scopes a call is resolved
// against. It is what `grammar expand` and `grammar normalize` share: gathering
// the files, keeping each directory's rules in a scope of their own, and holding
// the parsed trees alive for as long as those scopes are in use.
package astscope

import "core:bytes"
import "core:fmt"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../../ast"
import "../../token"
import "../check"

// File is one grammar file that was read and parsed. The source and the tree are
// kept here rather than by the caller, because a rule holds views into both: the
// name of an identifier is a slice of the source, and a rule body shares the
// arrays of the file it was parsed from. Both have to outlive every scope built
// from the file.
File :: struct {
	display: string, // the path used in diagnostics, owned
	src:     string, // the source text, a view over raw
	raw:     []byte, // the source bytes, owned
	file:    ast.File,
}

// Package is the set of grammar files in one directory, with the scope their
// rules form. A directory is a namespace, so a call into a sibling directory is
// not in this scope, and a command reports it rather than resolving it against a
// rule of the same name declared elsewhere.
Package :: struct {
	dir:   string, // the directory the files were read from, owned
	files: [dynamic]File,
	rules: [dynamic]ast.Rule, // every rule of every file, in file then source order
	scope: ast.Scope,
}

// Rules returns the rules of the package, in the order they were declared.
Rules :: proc(p: ^Package) -> []ast.Rule {
	return p.rules[:]
}

// Scope returns the scope the package's rules form. It is only read; the package
// frees it.
Scope :: proc(p: ^Package) -> ^ast.Scope {
	return &p.scope
}

// Files returns the files of the package, in the order they were read.
Files :: proc(p: ^Package) -> []File {
	return p.files[:]
}

// Display returns the path a file is reported under.
Display :: proc(f: ^File) -> string {
	return f.display
}

// Source returns the source text a file was parsed from.
Source :: proc(f: ^File) -> string {
	return f.src
}

// Tree returns the parsed file. It is only read; the package frees it.
Tree :: proc(f: ^File) -> ^ast.File {
	return &f.file
}

// Selects_File reports whether a selection names the file reported as display.
//
// A selection that names no file applies to every file. One that names a file is
// matched against the whole path and against the tail of it, because a directory is
// walked into absolute paths while a selection names a file relative to the working
// directory. So `b.grammar`, `pkg/b.grammar` and the absolute path of the file all
// pick the same one.
Selects_File :: proc(display: string, at: token.Selection) -> bool {
	if len(at.file) == 0 do return true
	if at.file == display do return true

	tail := len(at.file) + 1
	if len(display) > tail &&
			display[len(display)-tail] == '/' &&
			display[len(display)-len(at.file):] == at.file {
		return true
	}
	return false
}

// Load reads every grammar file under path and returns one package per directory
// that holds one. path is a file, in which case there is a single package, or a
// directory, which is walked recursively so that a subdirectory becomes a package
// of its own. Diagnostics are written to stderr as `name:line:col: message`, and a
// file that could not be read or parsed is left out and reported.
//
// The caller frees the result with Destroy_All.
Load :: proc(path: string, stderr: io.Writer, allocator := context.allocator) -> (
	packages: [dynamic]Package,
) {
	packages = make([dynamic]Package, allocator)

	files := check.collect_files(path, .Package, allocator)
	defer check.cleanup(files, allocator)

	for file in files {
		load_file(package_for(&packages, filepath.dir(file), allocator), file, stderr, allocator)
	}

	// A scope is built once every file of a directory is in, so that a rule may
	// call one declared later or in another file of the same directory.
	for i in 0 ..< len(packages) {
		packages[i].scope = ast.Build_Scope(packages[i].rules[:])
	}
	return packages
}

// package_for returns the package of dir, adding one when the directory has not
// been seen. The packages are searched in order, which keeps the result
// deterministic.
package_for :: proc(
	packages: ^[dynamic]Package,
	dir: string,
	allocator := context.allocator,
) -> ^Package {
	for i in 0 ..< len(packages) {
		if packages[i].dir == dir do return &packages[i]
	}
	append(packages, Package{dir = strings.clone(dir, allocator)})
	return &packages[len(packages) - 1]
}

// load_file reads and parses one file into its package, reporting whatever went
// wrong. A file that does not parse is left out: there is no tree to transform.
load_file :: proc(
	pkg: ^Package,
	path: string,
	stderr: io.Writer,
	allocator := context.allocator,
) {
	data, read_err := os.read_entire_file(path, allocator)
	if read_err != nil {
		io.write_string(stderr, fmt.tprintf("error: could not read '%s'\n", path))
		return
	}
	src := string(data)

	tokens, lex_errors := token.scan(src)
	defer delete(tokens)
	defer delete(lex_errors)

	parsed, parse_errors := ast.parse_file(src, tokens[:])
	defer delete(parse_errors)

	failed := false
	for e in lex_errors {
		report(stderr, path, src, e.offset, e.message)
		failed = true
	}
	for e in parse_errors {
		report(stderr, path, src, e.offset, e.message)
		failed = true
	}
	if failed {
		// The tree is incomplete, so nothing built from it can be trusted.
		ast.destroy_file(&parsed)
		delete(data, allocator)
		return
	}

	append(&pkg.files, File {
		display = strings.clone(path, allocator),
		src     = src,
		raw     = data,
		file    = parsed,
	})

	for decl in parsed.decls {
		rule := decl.(ast.Rule) or_continue
		append(&pkg.rules, rule)
	}
}

// report writes one diagnostic in the form the checker uses.
report :: proc(stderr: io.Writer, path, src: string, offset: int, message: string) {
	pos := token.position_at(src, offset)
	io.write_string(
		stderr,
		fmt.tprintf("%s:%d:%d: %s\n", path, pos.line, pos.column, message),
	)
}

// Destroy_All frees every package a Load returned and the list holding them.
Destroy_All :: proc(packages: [dynamic]Package, allocator := context.allocator) {
	// The scope goes before the files, since it holds the rules those files own.
	for i in 0 ..< len(packages) {
		ast.Destroy_Scope(&packages[i].scope)
	}
	for i in 0 ..< len(packages) {
		for j in 0 ..< len(packages[i].files) {
			ast.destroy_file(&packages[i].files[j].file)
			delete(packages[i].files[j].raw, allocator)
			delete(packages[i].files[j].display, allocator)
		}
		delete(packages[i].files)
		delete(packages[i].rules)
		delete(packages[i].dir, allocator)
	}
	delete(packages)
}

// Load_Source parses one source that is already in hand, as read from stdin, and
// returns it as a package of one. It reports the same diagnostics Load does and
// returns an empty list when the source does not parse, since there is no tree to
// transform.
//
// The caller frees the result with Destroy_All.
Load_Source :: proc(
	src, name: string,
	stderr: io.Writer,
	allocator := context.allocator,
) -> (packages: [dynamic]Package) {
	packages = make([dynamic]Package, allocator)

	tokens, lex_errors := token.scan(src)
	defer delete(tokens)
	defer delete(lex_errors)

	parsed, parse_errors := ast.parse_file(src, tokens[:])
	defer delete(parse_errors)

	failed := false
	for e in lex_errors {
		report(stderr, name, src, e.offset, e.message)
		failed = true
	}
	for e in parse_errors {
		report(stderr, name, src, e.offset, e.message)
		failed = true
	}
	if failed {
		ast.destroy_file(&parsed)
		return packages
	}

	append(
		&packages,
		Package {
			dir   = strings.clone(name, allocator),
			files = make([dynamic]File),
			rules = make([dynamic]ast.Rule),
		},
	)
	pkg := &packages[len(packages) - 1]

	append(
		&pkg.files,
		File {
			display = strings.clone(name, allocator),
			src     = src,
			raw     = nil,
			file    = parsed,
		},
	)
	for decl in parsed.decls {
		rule := decl.(ast.Rule) or_continue
		append(&pkg.rules, rule)
	}
	pkg.scope = ast.Build_Scope(pkg.rules[:])
	return packages
}

// Read_All reads a reader to the end. The returned bytes belong to the caller.
Read_All :: proc(r: io.Reader, allocator := context.allocator) -> (data: []byte, ok: bool) {
	buf: bytes.Buffer
	bytes.buffer_init(&buf, {})
	defer bytes.buffer_destroy(&buf)

	chunk := make([]byte, 8192, allocator)
	defer delete(chunk, allocator)

	for {
		n, err := io.read(r, chunk)
		if n > 0 do bytes.buffer_write(&buf, chunk[:n])
		if err != nil {
			if err == .EOF do break
			return nil, false
		}
		if n == 0 do break
	}

	data = bytes.clone(bytes.buffer_to_bytes(&buf), allocator)
	return data, true
}
