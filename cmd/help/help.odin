package help

import "core:fmt"

// Help texts are embedded from command/*.txt so the CLI output stays
// byte-identical to the canonical help files.
GRAMMAR :: string(#load("../../command/grammar.txt"))
CHECK   :: string(#load("../../command/check.txt"))
FMT     :: string(#load("../../command/fmt.txt"))
PRINT   :: string(#load("../../command/print.txt"))
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
	case "diff":
		return DIFF
	case "lsp":
		return LSP
	case:
		return ""
	}
}

// run prints the top-level help message.
run :: proc() {
	fmt.print(GRAMMAR)
}