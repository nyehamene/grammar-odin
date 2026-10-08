# Type checker

See cli interface in ../command/check.txt.

If PATH argument is a file, the check shoud load the file and its dependencies
(imported namespaces) into a compilation unit and perform type checking and
name resolution. (see Loading compilation unit section for details about how loading should be handled).

If PATH argument is a directory, the check should load all the grammar files in the directory
along with there dependencies into a compilation unit.
(see Loading compilation unit section for details about how loading should be handled)

## Goal

- Implement a type checker.

## Types

- The language has the following builtin primitive types:

  1. String. The type of every string literal. Ex. `"foo"`.
  2. Regexp. The type of every regular expression literal. Ex. `'[a-z]'`.

- A rule defines a variable of type `Production` whose value can be any valid expression.
- A binding defines a variable of type `Namespace`.

## Loading compilation unit

Namespace loading requires a compliation unit that maps the absolute path of a grammar
file to a `Namespace`. And is used for resoloving imported namespaces.

A Namespace is a structure that represents the semantic elements of all grammars files in a directory.
Specifically its rules (declaration). It maps each identifier to a Type.
Every declaration has an identifier. A declaration is bound to its identifier
in the containing/enclosing namespace.

### Scoping

A directory defines a namespace. All declarations in a directory leave in the same namespace.
Declarations are scopped to the namespace.

Binding (imported namespaces) are scoped to the enclosing file. Binding defined in a grammar
file are only visible within that file and cannot conflict with binding defined in other files
in the same namespce.

### Loading a file

The check follows these steps to load a file.

1. create a compilation unit if not already created.
2. create a `Namespace` object to represent the file.
2. load each namespace imported in the file into the compilation unit.
3. bind each imported namespace to their identifier in enclosing file scope.
4. bind each rule in the file to their identifier in the enclosing namespace.

### Loading a directory

The check follows these steps to load a directory.

1. create a compilation unit if not already created.
2. create a Namespace object for the directory.
3. start with any of the files (e.g. the first one).
4. load each namespace imported in the chosen file into the compilation unit.
5. bind each imported namespace to their identifier in enclosing file scope.
6. bind each rule in the file to their identifier in the enclosing namespace.

## Symatic Analysis

### Rule visibility

A rule name determines how far it reaches.

| Name starts with | Tier       | Reachable from                        | Reported unused |
|------------------|------------|---------------------------------------|-----------------|
| uppercase        | exported   | its own namespace, and any that imports it | no          |
| lowercase        | local      | every file of its own namespace        | yes, if nothing in the namespace names it |
| `_`             | private    | the file it was declared in           | yes, if nothing in the file names it |

A member access expression has a receiver and an object: `receiver.object`.

- The receiver must resolve to a value of type `Namespace`.
- The object must resolve to a value of type `Production` in the receiver namespace.
- The object must be exported. A local or private rule of the receiver namespace
  is not reachable through a binding, and this is reported separately from a
  rule that does not exist, because the rule is there and merely out of reach:

  ```
  ns.helper is not exported. only a rule whose name starts with an uppercase letter is accessible from another namespace
  ```

  The server follows the checker here: definition, hover and signature help do
  not resolve a non-exported member, and member completion does not offer one.

## Implementation

- Every directory is a namespace. All the grammar files in the directory are in the same namespace.
- A rule must have a value. It is an error if no value is provided.
- Exported rules are accessible from external namespaces via binding variables.
  Local and private rules are not, even when they live in an imported namespace.
- The `@import` directive is used to import a namespace and bind it to a variable.
- The import path is resolved relative to the directory containing the importing namespace.
- It is an error if the imported directory does not exist.
- Exported rules defined in an imported namespace are accessible through the binding variable.
- It is an error to access a non-existent rule.
- It is an error to access a non-exported rule through a binding variable.
- It is an error if 2 or more declarations in a namespace name the same declaration.
  A name and an arity together name one declaration, so a rule and a proc of one name
  are two declarations and neither redeclares the other, while two declarations at the
  same arity are the same declaration twice. A rule cannot have the same name as a
  binding variable in the same file.
- A name in production position is a reference to the rule of that name, which is the
  declaration of no parameters. A name declared only as procs is not a production, and
  using one there is an error.
- A call names a proc, and resolves to the declaration of that name at the number of
  arguments it passes. It is an error if no proc of that name is declared at that arity,
  and the error says which arities are declared, since those are the calls that would
  have worked.
- Binding variables are scoped to the file they are declared
- Declarations are scoped to the namespace.
- Name checker should detect and report import cycles as errors.

## Example
  For example: given a folder with the following file structure

  ```sh
  pkg/foo/foo.grammar
  pkg/bar/bar.grammar
  pkg/bar/baz.grammar
  ```

  Where pkg/foo.grammar has the following content:
  ```
  // pkg/foo/foo.grammar
  Foo = "i am foo";
  ```

  And, baz.grammar has the following content:
  ```
  // pkg/bar/baz.grammar
  Baz = "i am baz";
  ```

  And, bar.grammar has content.
  ```
  // pkg/bar/bar.grammar
  F = @import("pkg/foo");
  X = @import("pkg/xxx"); // error: "namespace xxx does not exist"

  // `tag` is a local rule: usable anywhere in this namespace, not from another
  // one, and reported only when nothing here names it.
  tag = "grammar";

  Ident = F.Foo Baz tag;

  x1 = F.Other; // error: "F.Other is undefined. namespace foo has no field Other"
  ident = "foo"; // error: "field ident redeclared in this namespace. (see other declaration at <INSERT LINE:COLUMN HERE>)"
  ```

## Warnings

Not everything the checker finds should fail the build. A declaration that
nothing refers to is usually leftover rather than broken, so it is reported as a
warning, alongside the errors, and `check` still exits `0`:

```sh
$ cat main.grammar
used = "a";
unused = "b";
Start = used;

$ grammar check main.grammar --file
main.grammar:2:1: warning: unused local rule: unused
$ echo $?
0
```

The rules that decide what gets reported are in
[10-unused-warning.md](10-unused-warning.md). In short: a private rule unused
within its file, a local rule unused within its namespace, and a binding nothing
in its file names are warnings; an exported rule is never reported unused; and
an unused parameter is an error.

The server publishes these with severity `2` so a client can render them without
treating them as failures.
