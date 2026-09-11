## Project Overview

This project is a tool for a custom grammar language.
The language is used to describe the syntax of other programming languages.
The tool provides a checker, a formatter, and a language server for this grammar language.

The project is structured into several packages:
- `cmd`: Contains the implementation of the command-line tool and its subcommands.
- `token`: Contains the tokenizer for the grammar language.
- `ast`: Contains the abstract syntax tree representation, the parser, and the AST printer.
- `example`: Contains example grammar files.

## Building and Running

The project uses a `Justfile` for common tasks.

- **Build:** To build the `grammar` binary, run:
  ```sh
  just build
  ```

- **Test:** To run the tests, run:
  ```sh
  just test
  ```

- **Run:** To run the `grammar` tool, run:
  ```sh
  just run ARGS="<arguments>"
  ```

- **Clean:** To clean the build artifacts, run:
  ```sh
  just clean
  ```

## Development Conventions

The project follows standard Odin conventions.
The implementation is guided by the markdown files in the `implementation` directory.
