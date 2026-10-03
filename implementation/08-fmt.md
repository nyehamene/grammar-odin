# Formatter

Formats input files inplace. If an error is found
the file containing the error is not modified, and
the program reports the errors and exit with a non-zero
exit code after formatting all the input files.

- [x] Implement `grammar fmt PATH`.
- [x] Add tests using the rules described below.
- [x] Implement `grammar fmt --stdin`.
- [x] Implement `grammar fmt --stdout PATH`.
- [ ] Implement `grammar fmt --separator N`.

## Formating rules

### Golden rule

The formatter is only allowed to add newlines between groups (see rules 1 and 6).
Any newlines existing in the source must be preserved, but trailing blank lines
at the end of the file should collapse to 1. The number of newlines added to
separate groups depends on the flag `--separator N` (see ../command/fmt.txt).
Boundary runs (blank lines between groups) longer than the value given by
`--separator` are preserved.

### Other rules

1. Rule Grouping: alignment of consecutive rules.
  Rules not separated by blank lines should be aligned
  so that the value separator `=` are on the same column.

  For example,

  Before:
  ```grammar
  a = "a";
  bar = "bar";

  b = "a";
  name = "name";
  ```

  After:
  ```grammar
  a   = "a";
  bar = "bar";

  b    = "a";
  name = "name";
  ```

2. Add a space around values inside grouping symbols
  like `(` and `)`, `[` and `]`, `{` and `}`, etc.

  For example,

  Before:
  ```grammmar
  one = (foo);
  two = [bar];
  xxx = {baz};
  ```

  After:
  ```grammar
  one = ( foo );
  two = [ bar ];
  xxx = { baz };
  ```

3. Add a space around the alternative separator `|`.

  Before:
  ```grammar
  foo = a|b;
  ```

  After:
  ```grammar
  foo = a | b;
  ```

4. Production (or expression) Group: alignment of expression.
  When arranging alternative vertically, align the
  value separator `=`, alternative separator `|`
  and rule separator `;` on the same column.

  Before:
  ```grammar
  choice = one
     | two
     | three ;
  ```

  After:
  ```grammar
  choice = one
         | two
         | three;
  ```

Combing rule 1 and 4, given the following text:

Before:
```grammar
x = "one";
xxx = "one"
  | "two"
  | "three";
xx = "two";
```
After formatting should produce the following:

After:
```grammar
x   = "one";
xxx = "one"
    | "two"
    | "three";
xx  = "two";
```

The rules are grouped together until there is a blank line separating.
The productions in the second rule is also aligned to match the group
alignment before it spans multiple lines.

5. Continuation Indent: alignment of unlabeled continuation lines.
  In a vertically arranged production, a line that does not begin with the
  alternative separator `|` continues the alternative above it rather than
  starting a new one. Indent such a line one column past the group alignment
  column so that it reads as a continuation instead of as a sibling of the
  `|` lines. The value separator `=`, the alternative separator `|` and the
  rule separator `;` all remain on the alignment column.

  Before:
  ```grammar
  choice = one
     other
     | two
     | three ;
  ```

  After:
  ```grammar
  choice = one
           other
         | two
         | three;
  ```

6. Rule Grouping: alignment of consecutive rules.
  Rules are aligned so that the value separator `=` lands on the same column,
  unless they are separated by a run of at least `--separator` blank lines. A
  run shorter than `--separator` is interior whitespace inside a group and
  does not break the alignment.
  Assuming `--separator 2` is given.

  For example,

  Before:
  ```grammar
  a = "a";

  bar = "bar";


  b = "a";
  name = "name";
  ```

  After:
  ```grammar
  a   = "a";

  bar = "bar";


  b    = "a";
  name = "name";
  ```

## Example

Formatting the following text:

```grammar
/// @var
document = @import("document.grammar");
component = @import("component.grammar");

/// @ast
Source = DocumentNamespace | ComponentNamespace;
DocumentNamespace = document;
ComponentNamespace = component;
```

Should output the following:
```grammar
/// @var
document  = @import("document.grammar");
component = @import("component.grammar");

/// @ast
Source             = DocumentNamespace | ComponentNamespace;
DocumentNamespace  = document;
ComponentNamespace = component;
```
