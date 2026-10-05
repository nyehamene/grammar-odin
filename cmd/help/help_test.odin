package help

import "core:bytes"
import "core:strings"
import "core:testing"

@(test)
test_run_writes_to_writer :: proc(t: ^testing.T) {
	buf: bytes.Buffer
	bytes.buffer_init(&buf, {})
	defer bytes.buffer_destroy(&buf)

	run(bytes.buffer_to_stream(&buf))

	testing.expect(t, bytes.buffer_to_string(&buf) == GRAMMAR, "run should write the main help text")
}

@(test)
test_grammar_help_text :: proc(t: ^testing.T) {
	testing.expect(t, strings.has_prefix(GRAMMAR, "Usage: grammar COMMAND"), "main help should begin with usage")
	testing.expect(t, strings.contains(GRAMMAR, "fmt        Format grammar files inplace."), "main help should list fmt")
	testing.expect(t, strings.contains(GRAMMAR, "version    Print version infomation."), "main help should list version")
	testing.expect(t, strings.contains(GRAMMAR, "expand"), "main help should list expand")
	testing.expect(t, strings.contains(GRAMMAR, "normalize"), "main help should list normalize")
}

@(test)
test_check_help_text :: proc(t: ^testing.T) {
	testing.expect(t, strings.has_prefix(CHECK, "Usage: grammar check ARGUMENT [ OPTION ]"), "check help should begin with usage")
	testing.expect(t, strings.contains(CHECK, "--stdin"), "check help should mention --stdin")
	testing.expect(t, strings.contains(CHECK, "--package"), "check help should mention --package")
}

@(test)
test_fmt_help_text :: proc(t: ^testing.T) {
	testing.expect(t, strings.has_prefix(FMT, "Usage: grammar fmt ARGUMENT"), "fmt help should begin with usage")
	testing.expect(t, strings.contains(FMT, "--stdout"), "fmt help should mention --stdout")
}

@(test)
test_expand_help_text :: proc(t: ^testing.T) {
	testing.expect(t, strings.has_prefix(EXPAND, "Usage: grammar expand ARGUMENT"), "expand help should begin with usage")
	testing.expect(t, strings.contains(EXPAND, "--write"), "expand help should mention --write")
	testing.expect(t, strings.contains(EXPAND, "--tree"), "expand help should mention --tree")
	testing.expect(t, strings.contains(EXPAND, "--stdin"), "expand help should mention --stdin")
	testing.expect(t, strings.contains(EXPAND, "--select"), "expand help should mention --select")
}

@(test)
test_normalize_help_text :: proc(t: ^testing.T) {
	testing.expect(t, strings.has_prefix(NORMALIZE, "Usage: grammar normalize ARGUMENT"), "normalize help should begin with usage")
	testing.expect(t, strings.contains(NORMALIZE, "--tags"), "normalize help should mention --tags")
	testing.expect(t, strings.contains(NORMALIZE, "strip"), "normalize help should name the default policy")
	testing.expect(t, strings.contains(NORMALIZE, "--select"), "normalize help should mention --select")
}

@(test)
test_print_help_text :: proc(t: ^testing.T) {
	testing.expect(t, strings.has_prefix(PRINT, "Usage: grammar print ARGUMENT PATH"), "print help should begin with usage")
	testing.expect(t, strings.contains(PRINT, "--token"), "print help should mention --token")
}

@(test)
test_diff_help_text :: proc(t: ^testing.T) {
	testing.expect(t, strings.has_prefix(DIFF, "Usage: grammar diff ARGUMENT PATH1 PATH2"), "diff help should begin with usage")
}

@(test)
test_lsp_help_text :: proc(t: ^testing.T) {
	testing.expect(t, strings.has_prefix(LSP, "Usage: grammar lsp"), "lsp help should begin with usage")
	testing.expect(t, strings.contains(LSP, "--log-format"), "lsp help should mention --log-format")
}

@(test)
test_text_for :: proc(t: ^testing.T) {
	testing.expect(t, text_for("check") == CHECK, "text_for should return check help")
	testing.expect(t, text_for("fmt") == FMT, "text_for should return fmt help")
	testing.expect(t, text_for("print") == PRINT, "text_for should return print help")
	testing.expect(t, text_for("diff") == DIFF, "text_for should return diff help")
	testing.expect(t, text_for("lsp") == LSP, "text_for should return lsp help")
	testing.expect(t, text_for("help") == "", "text_for should return empty for help")
	testing.expect(t, text_for("version") == "", "text_for should return empty for version")
	testing.expect(t, text_for("bogus") == "", "text_for should return empty for unknown command")
}