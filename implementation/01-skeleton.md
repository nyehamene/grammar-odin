# Skeleton

Project initialization and Version control initialization.

Create a minimal executable named `grammar`  with the following
functinalities.

- Implement `grammar fmt` command that prints "Formatting <INSERT INPUT FILE NAME>..." to stdout.
- Implement `grammar check` command that prints "Validating <INSERT INPUT FILE NAME>..." to stdout.
- Implement `grammar lsp` command that prints "TBD".
- Implement `grammar help` command that prints "TBD".
- Implement `grammar version` command that prints "TBD".

The program should exit with 0 exit code.

The implementation should include proper logging messages
for debugging.

## Implementation note for command that take input PATH.

The program should only work with files in the current working director
where it is run and reject path that point to files outside that directory.

For example, the program should reject the following paths:

Reject paths outside cwd.
- /example.txt
- /example/foo.txt
- ../example.txt
- ../example/foo.txt

Accept relative paths inside cwd.
- example.txt
- ./example.txt
- ./example/foo.txt
