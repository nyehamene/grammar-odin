# Unused warning

The check and lsp should report a warning or unused rules, bindings, and parameters.

## Definition of terms

1. Exported rule - A rule with name starting with uppercase is exported.
   An exported rule is accessible from other namespace.

2. Local rule - A rule with name starting with lowercase is local to the namespace.
   An is accessible from any file within the namespace.

3. Private rule - A rule with name starting with underscore `_` is private to
   the file it was declared. Private rules are accessible only within the file
   they are declared.

NOTE: in the current implementation local rule is actually private rule.
So the terms should be updated as describe above.

## Warnings

1. Private rule - report a warning when unused within the file.
2. Local rule - report a warning when unused within the namespace.
3. Exported rule - never report unused error.
4. Parameter - report a warning when unused.
5. binding - report a warning when unused.

