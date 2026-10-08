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

## Warnings

1. Private rule - report a warning when unused within the file.
2. Local rule - report a warning when unused within the namespace.
3. Exported rule - never report unused error.
4. Parameter - report a warning when unused.
5. binding - report a warning when unused.

## What counts as a use

A use is a direct reference to the rule or binding. Naming a rule inside the rule
it names does not count, so

    helper = helper | "x";

reports `helper` as unused even though the name appears on the right-hand side.

Mutual recursion does count, because each rule names the other:

    ping = pong;
    pong = ping;

Neither rule is reported.

Referring to a rule through a binding in another namespace is a use of that rule,
and it is only possible at all because an exported rule is reachable from there.
This is why visibility is enforced rather than merely documented: if
`ns.helper` were allowed to resolve a local rule of another namespace, then
"unused within the namespace" would stop being true, since a rule could be named
from outside while every rule inside its namespace ignored it.

## Diagnostics

A warning is a `Semantic_Error` with severity `Warning`. `check` prints it as

    path:line:column: warning: unused local rule: helper

and still exits `0`. Errors keep their previous formatting and exit `1`. The
server publishes a warning with JSON-RPC severity `2`.

Warnings are skipped for a file that failed to lex or parse, since the rule list
is incomplete and every rule would look unused. They are also skipped for a
declaration that lost a redeclaration contest, so only the registration that
actually holds the name is considered.

Each proc of a name is a declaration of its own and is reported on its own:

    path:line:column: warning: unused local proc: pair with 2 parameters

Uses are counted per declaration rather than per name, so a call of one arity is a
use of that proc and says nothing about the others. Without that, `foo x = x;` and
`foo x y = x y;` would mask each other and neither would be reported once anything
called `foo`.

`check --stdin` lexes and parses only, so it never reports these warnings.

## Deviation

Item 4 of the list above asks for a warning on an unused parameter. Parameters
are reported as an error instead:

    path:line:column: unused proc parameter: x

An unused parameter is more often a mistake in the rule body than a leftover,
and it is worth surfacing at the same strength as the other semantic errors.
This is a deliberate departure from the item as written.
