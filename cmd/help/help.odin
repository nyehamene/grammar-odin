package help

import "core:io"

// Help texts are embedded from command/*.txt so the CLI output stays
// byte-identical to the canonical help files.
GRAMMAR :: string(#load("../../command/grammar.txt"))
CHECK   :: string(#load("../../command/check.txt"))
FMT     :: string(#load("../../command/fmt.txt"))
PRINT   :: string(#load("../../command/print.txt"))
EXPAND  :: string(#load("../../command/expand.txt"))
NORMALIZE :: string(#load("../../command/normalize.txt"))
DIFF    :: string(#load("../../command/diff.txt"))
LSP     :: string(#load("../../command/lsp.txt"))

// text_for returns the help text for a subcommand, or "" if the command has
// no dedicated help text.
text_for :: proc(command: string) -> string {
	switch command {
	case "check":
		return CHECK
	case "fmt":
		return FMT
	case "print":
		return PRINT
	case "expand":
		return EXPAND
	case "normalize":
		return NORMALIZE
	case "diff":
		return DIFF
	case "lsp":
		return LSP
	case:
		return ""
	}
}

// run writes the top-level help message to the given writer.
run :: proc(writer: io.Writer) {
	io.write_string(writer, GRAMMAR)
}