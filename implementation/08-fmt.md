# Formatter

Formats input files inplace. If an error is found
the file containing the error is not modified, and
the program reports the errors and exit with a non-zero
exit code after formatting all the input files.

- [x] Implement `grammar fmt PATH`.
- [x] Add tests using the rules described below.
- [x] Implement `grammar fmt --stdin`.

## Formating rules

### Golden rule

The formatter must not add/remove newlines ("\n"). It is allowed to add or remove spaces
and align tokens but must never add or remove newlines. Any newlines existing in the source
must be preserved. No other rule below must violate this rule.

### Other rules

1. Rule Grouping: alignment of consecutive rules.
  Rules not separated by a blank line should be aligned
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
         | three
         ;
  ```

5. Trim consecutive blank lines.

  Before:
  ```grammar
  foo = "one";


  bar = "bar";
  ```

  After:
  ```grammar
  foo = "one";

  bar = "bar";
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
x    = "one";
xxxx = "one"
     | "two"
     | "three"
     ;
xx   = "two";
```

The rules are grouped together before there is blank line separating.
The productions in the second rule is also aligned to match the group
alignment before it spans multiple lines.

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
