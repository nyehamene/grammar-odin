# Grammar

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A domain-specific language for describing programming language syntax.

## Overview

Grammar is a tool and DSL for defining the syntax of programming languages. It provides:

- **Checker** - Validate grammar files and report diagnostic errors
- **Formatter** - Format grammar files with configurable style
- **Print** - Output tokens or AST nodes for debugging
- **Language Server** - IDE support via LSP (completion, hover, go-to-definition, etc.)

## Installation

## CLI Interface

```
Usage: grammar COMMAND

A tool for describing the syntax of programming languages.

Command:
fmt      Format grammar files inplace.
check    Validate grammar files and report diagnostic errors.
print    Print tokens or Ast nodes.
lsp      Start a language server.
help     Print this message.
version  Print version information.

An grammar file is any file with the file extension .grammar.
```

## Quick Start

```bash
# Check a grammar file
grammar check mylang.grammar

# Format a grammar file
grammar fmt mylang.grammar

# Start the language server
grammar lsp
```

## Grammar Syntax

A grammar file (`.grammar`) defines language syntax using rules and bindings.

### Rules

```grammar
// A rule defines a named production
Greeting = "Hello" | "Hi";

// Rules can reference other rules
Full_Greeting = Greeting " World";

// A rule can have parameters
Greet name title = "hello" name title;

// Pass arguments to a rule
Person = "John";
Fancy_Greeting = <Greet Person "Mr">;
```

### Rule Visibility

A rule's first letter decides how far it is visible.

| Name | Kind | Visible in |
| --- | --- | --- |
| `Greeting` | exported | its own namespace, and any namespace that imports it |
| `greeting` | local | every file of its own namespace |
| `_helper` | private | only the file that declares it |

```grammar
// A private rule: an underscore followed by a letter.
_helper = "hello";

// Private rules are used like any other rule, but only inside this file.
Greeting = _helper "!";
```

A private rule is never added to the namespace, so two files in the same
namespace may each declare their own `_helper`, and neither can see the other's.

Only an exported rule is reachable through an import: `mylang.helper` is an
error when `helper` is declared with a lowercase name or an underscore.

`_`, `_1x` and `__x` are reported as malformed private rule names; they are
registered as namespace rules instead, so the rest of the file keeps resolving.

### Bindings (Imports)

```grammar
// Import another grammar namespace
Base = @import("base");

// Reference exported rules from the imported namespace
Base_Rule = Base.Identifier;
```

### Expressions

These snippets show the forms rather than a working grammar, so nothing refers
to them and `grammar check` would report each one as an unused local rule.

```grammar
// String literals
str = "hello";

// Regular expressions
regex = '[a-z]+';

// Groups
grouped = ( "a" "b" );

// Repetition: zero or more
repeated = { "a" };

// Optional: zero or one
optional = [ "b" ];

// External rule
external = __name__;
```

### Directives

```grammar
// Import from package directory
pkg = @import("mylib");
```

A binding whose namespace is never named is reported as unused.

## Commands

### `grammar check`

Validate grammar files and report errors and warnings:

```bash
grammar check path/to/file.grammar --file
grammar check path/to/directory --package
grammar check path/to/directory
```

A rule or binding that nothing refers to is reported as a warning, not an
error:

```console
$ grammar check main.grammar --file
main.grammar:2:1: warning: unused local rule: helper
$ echo $?
0
```

Warnings are printed with a `warning:` prefix and never affect the exit code, so
a leftover rule will not fail a build that only cares about correctness. Judge
by the exit code, not by whether there was output. An unused proc parameter is
still an error, since it usually means the rule body is wrong.

### `grammar fmt`

Format grammar files:

```bash
grammar fmt path/to/file.grammar   --file     # Format in place
grammar fmt path/to/folder         --package  # Format in place
grammar fmt --stdout file.grammar  --file     # Output to stdout
grammar fmt --stdin                           # Format from stdin
```

### `grammar print`

Print tokens or AST for debugging:

```bash
grammar print --token file.grammar
grammar print --ast file.grammar
```

### `grammar lsp`

Start the Language Server Protocol server for IDE integration:

```bash
grammar lsp                         # Default (no logging)
grammar lsp --log server.log        # Log to file
grammar lsp --log --log-format json # JSON log format
grammar lsp --log --log-level info  # Set log level
```

## Language Server Features

The Grammar language server provides IDE support including:

- **Completion** - Auto-complete rule names, imports, and package members
- **Hover** - Show type information on hover
- **Go to Definition** - Navigate to rule definitions
- **Find References** - Find all usages of a rule
- **Document Symbols** - Outline view of grammar file
- **Workspace Symbols** - Outline view of grammar file
- **Diagnostics** - Real-time error checking
- **Document Links** - Navigate between imported files
- **Formatting** - Document formatting support

## Project Structure

```
.
├── cmd/             # CLI commands
│   ├── check/       # Validation command
│   ├── fmt/         # Formatter command
│   ├── lsp/         # Language server
│   ├── diff/        # Diff command
│   └── print/       # Print command
├── ast/             # Abstract Syntax Tree
├── check/           # Semantic checking
├── token/           # Tokenizer
├── log/             # Logging utilities
├── server/          # LSP implementation
└── command/         # CLI help text
```

## Development

### Running Tests

```bash
just test
```

### Building

```bash
just build
```

## License

MIT License - see [LICENSE](LICENSE) for details.

## Contributing

Contributions are welcome! Please open an issue or submit a pull request on the [GitHub repository](https://github.com/better-tools/better-grammar).
