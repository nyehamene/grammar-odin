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

### Member access

A member access expression has a receiver and an object: `receiver.object`.

- The receiver must resolve to a value of type `Namespace`.
- The object must resolve to a value of type `Production` in the receiver namespace.

## Implementation

- Every directory is a namespace. All the grammar files in the directory are in the same namespace.
- A rule must have a value. It is an error if no value is provided.
- Rules are exported and are accessible from external namespaces via binding variables.
- The `@import` directive is used to import a namespace and bind it to a variable.
- The import path is resolved relative to the directory containing the importing namespace.
- It is an error if the imported directory does not exist.
- Rules defined in an imported namespace are accessible through the binding variable.
- It is an error to access a non-existent rule.
- It is an error if 2 or more declarations in a namespace have the same name (identifier).
  A rule cannot have the same name as another rule in the same namespace.
  A rule cannot have the same name as a binding variable in the same file.
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
  foo = "i am foo";
  ```

  And, baz.grammar has the following content:
  ```
  // pkg/bar/baz.grammar
  baz = "i am baz";
  ```

  And, bar.grammar has content.
  ```
  // pkg/bar/bar.grammar
  f = @import("pkg/foo");
  x = @import("pkg/xxx"); // error: "namespace xxx does not exist"

  ident = f.foo baz;

  x1 = f.other; // error: "f.other is undefined. namespace foo has no field other"
  ident = "foo"; // error: "field ident redeclared in this namespace. (see other declaration at <INSERT LINE:COLUMN HERE>)"
  ```

