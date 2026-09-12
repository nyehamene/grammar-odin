package token

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_scan_simple_rule :: proc(t: ^testing.T) {
	tokens, errors := scan(`greeting = "Hello" | "Hi";`)
	defer delete(tokens)
	defer delete(errors)

	expect_kinds(t, tokens[:], []Kind{.Ident, .Equal, .String, .Pipe, .String, .Semicolon, .EOF})
	testing.expect(t, len(errors) == 0, "no errors expected")
}

@(test)
test_scan_comment_and_newlines :: proc(t: ^testing.T) {
	tokens, errors := scan("// a comment\nx = \"y\";\n")
	defer delete(tokens)
	defer delete(errors)

	expect_kinds(t, tokens[:], []Kind{.Comment, .Ident, .Equal, .String, .Semicolon, .EOF})
	testing.expect(t, len(errors) == 0, "no errors expected")
}

@(test)
test_scan_external_ident :: proc(t: ^testing.T) {
	src := `e = __name__;`
	tokens, errors := scan(src)
	defer delete(tokens)
	defer delete(errors)

	expect_kinds(t, tokens[:], []Kind{.Ident, .Equal, .External, .Semicolon, .EOF})
	testing.expect(t, len(errors) == 0, "no errors expected")
	testing.expect(t, lexeme(tokens[2], src) == "__name__", "external lexeme should be __name__")
}

@(test)
test_scan_member_access :: proc(t: ^testing.T) {
	tokens, errors := scan(`m = foo.bar;`)
	defer delete(tokens)
	defer delete(errors)

	expect_kinds(t, tokens[:], []Kind{.Ident, .Equal, .Ident, .Dot, .Ident, .Semicolon, .EOF})
	testing.expect(t, len(errors) == 0, "no errors expected")
}

@(test)
test_scan_regexp :: proc(t: ^testing.T) {
	tokens, errors := scan(`r = '[a-z]+';`)
	defer delete(tokens)
	defer delete(errors)

	expect_kinds(t, tokens[:], []Kind{.Ident, .Equal, .Regexp, .Semicolon, .EOF})
	testing.expect(t, len(errors) == 0, "no errors expected")
}

@(test)
test_scan_grouping_and_call :: proc(t: ^testing.T) {
	tokens, errors := scan(`( "a" { "b" } [ "c" ] ) | <rule x 1>`)
	defer delete(tokens)
	defer delete(errors)

	expect_kinds(t, tokens[:], []Kind{
		.LParen, .String, .LBrace, .String, .RBrace, .LBrack, .String, .RBrack, .RParen,
		.Pipe, .Lt, .Ident, .Ident, .Illegal, .Gt, .EOF,
	})
	testing.expect(t, len(errors) == 1, "expected one illegal-character error")
}

@(test)
test_scan_import_directive :: proc(t: ^testing.T) {
	src := `x = @import("base");`
	tokens, errors := scan(src)
	defer delete(tokens)
	defer delete(errors)

	expect_kinds(t, tokens[:], []Kind{.Ident, .Equal, .At, .Ident, .LParen, .String, .RParen, .Semicolon, .EOF})
	testing.expect(t, lexeme(tokens[2], src) == "@", "directive marker scans as its own token")
	testing.expect(t, lexeme(tokens[3], src) == "import", "directive name scans as a separate ident")
	testing.expect(t, len(errors) == 0, "no errors expected")
}

@(test)
test_scan_unsupported_number_is_illegal :: proc(t: ^testing.T) {
	tokens, errors := scan(`x = "1"; y = 42;`)
	defer delete(tokens)
	defer delete(errors)

	expect_kinds(t, tokens[:], []Kind{.Ident, .Equal, .String, .Semicolon, .Ident, .Equal, .Illegal, .Illegal, .Semicolon, .EOF})
	testing.expect(t, len(errors) == 2, "expected two illegal-character errors")
}

@(test)
test_scan_unterminated_string :: proc(t: ^testing.T) {
	tokens, errors := scan(`x = "never closed`)
	defer delete(tokens)
	defer delete(errors)

	testing.expect(t, len(errors) == 1, "expected one error")
	testing.expect(t, errors[0].message == "unterminated string literal", "wrong error message")
}

@(test)
test_scan_unterminated_regexp :: proc(t: ^testing.T) {
	tokens, errors := scan(`x = '[a-z]`)
	defer delete(tokens)
	defer delete(errors)

	testing.expect(t, len(errors) == 1, "expected one error")
	testing.expect(t, errors[0].message == "unterminated regexp literal", "wrong error message")
}

@(test)
test_position_at :: proc(t: ^testing.T) {
	src := "ab\ncd\nef"
	testing.expect(t, position_at(src, 0) == Position{1, 1}, "offset 0")
	testing.expect(t, position_at(src, 2) == Position{1, 3}, "offset 2")
	testing.expect(t, position_at(src, 3) == Position{2, 1}, "offset 3")
	testing.expect(t, position_at(src, 5) == Position{2, 3}, "offset 5")
	testing.expect(t, position_at(src, 7) == Position{3, 2}, "offset 7")
}

@(test)
test_example_files_scan_cleanly :: proc(t: ^testing.T) {
	files := collect_example_grammars(t)
	defer delete_files(files)
	for file in files {
		data, err := os.read_entire_file_from_path(file, context.allocator)
		if err != nil {
			testing.expectf(t, false, "could not read %s", file)
			continue
		}
		_, errors := scan(string(data))
		if len(errors) > 0 {
			testing.expectf(t, false, "%s: expected clean tokenization, got %s", file, error_summary(errors[:]))
		}
	}
}

delete_files :: proc(files: [dynamic]string) {
	for f in files do delete(f)
	delete(files)
}

expect_kinds :: proc(t: ^testing.T, tokens: []Token, expected: []Kind) {
	if len(tokens) != len(expected) {
		testing.expectf(t, false, "expected %d tokens, got %d", len(expected), len(tokens))
		return
	}
	for tok, i in tokens {
		if tok.kind != expected[i] {
			testing.expectf(t, false, "token %d: expected kind %q, got %q", i, kind_name(expected[i]), kind_name(tok.kind))
		}
	}
}

error_summary :: proc(errors: []Error) -> string {
	if len(errors) == 0 do return ""
	return fmt.tprintf("(%d errors, first: %s)", len(errors), errors[0].message)
}

// collect_example_grammars walks ../example and returns every .grammar file.
collect_example_grammars :: proc(t: ^testing.T) -> [dynamic]string {
	w := os.walker_create("../example")
	defer os.walker_destroy(&w)

	files := make([dynamic]string)
	for info in os.walker_walk(&w) {
		if info.type == .Regular && strings.has_suffix(info.fullpath, ".grammar") {
			append(&files, strings.clone(info.fullpath))
		}
	}
	return files
}