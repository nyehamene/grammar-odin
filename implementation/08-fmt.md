# Formatter

Formats input files inplace. If an error is found
the file containing the error is not modified, and
the program reports the errors and exit with a non-zero
exit code after formatting all the input files.

- [x] Implement `grammar fmt PATH`.
- [x] Add tests using the rules described below.
- [x] Implement `grammar fmt --stdin`.
- [x] Implement `grammar fmt --stdout PATH`.
- [x] Implement `grammar fmt --separator N`.

## Formating rules

### Golden rule

The formatter is only allowed to add newlines between groups (see rule 1).
Any newlines existing in the source must be preserved, but trailing blank lines
at the end of the file should collapse to 1. The number of newlines added to
separate groups depends on the flag `--separator N` (see ../command/fmt.txt).
Boundary runs (blank lines between groups) longer than the value given by
`--separator` are preserved.

### Other rules

1. Rule Grouping: alignment of consecutive rules.
  Rules are aligned so that the value separator `=` lands on the same column.
  A group ends at a run of at least `--separator` blank lines (see
  ../command/fmt.txt); a shorter run is interior whitespace inside the group
  and does not break the alignment. A boundary run longer than `--separator` is
  kept at its original length.

  The same input formats differently depending on the threshold. Before, with
  one blank line before `bar` and two before `b`:

  ```grammar
  a = "a";

  bar = "bar";


  b = "a";
  name = "name";
  ```

  After, at the default `--separator 1`, where the single blank ends a group
  and `a` is padded only against itself:

  ```grammar
  a = "a";

  bar = "bar";


  b    = "a";
  name = "name";
  ```

  After, with `--separator 2`, where the single blank is interior, so `a` and
  `bar` share a group and `a` is padded out to `bar`:

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
  ```grammar
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

  The rule separator may also sit on a line of its own. It keeps that line, but
  lands on the same column.

  Before:
  ```grammar
  choice = one
     | two
     ;
  ```

  After:
  ```grammar
  choice = one
         | two
         ;
  ```

Combining rule 1 and 4, given the following text:

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

6. Align the parameters of all the functions in a group

  With `--separator 1`

  Before:
  ```grammar
  foo x y = x y;
  f x = x;

  bar xx y = xx y
  b x y = x y
  ```

  After:
  ```grammar
  foo x y = x y;
  f     x = x;

  bar xx y = xx y
  b    x y = x y
  ```

  The columns are counted back from the last parameter, so a rule that declares
  fewer parameters still writes its last one under the last one of its
  neighbours, and an earlier parameter is right aligned in a cell as wide as the
  widest parameter of its column. Above, `x` is written in the column of `xx`.

7. Write a tag in one canonical spelling.

  A tag holds `name="value"` pairs (see ../implementation/11-tag.md). The spaces
  a source may put around `=` and after `;` are not kept: no space around `=`,
  one space after each `;`. The values are string literals, so their quotes and
  any `;` or quote inside them are left exactly as written. The tag itself is
  never split, and it sits outside a group, a repetition or an optional that it
  annotates, since that is the only place the parser accepts it.

  Before:
  ```grammar
  foo = a `name = "a";other="b"`;
  bar = a b `  note = "x; y" ;  n="100"  `;
  baz = ( a ) `n="1"`;
  ```

  After:
  ```grammar
  foo = a `name="a"; other="b"`;
  bar = a b `note="x; y"; n="100"`;
  baz = ( a ) `n="1"`;
  ```

8. Align tags in a rule when aligning alternatives

  Before:
  ```
  foo = a b `tag`
    | xxxxxx `tag`
    | x `tag`
    ;
  ```

   After:
   ```
   foo = a b    `tag`
       | xxxxxx `tag`
       | x      `tag`
       ;
   ```

   The column is one space past the widest line of the rule, so every tag starts in
   the same column. Note that `` `tag` `` stands for a tag such as `name="a"`: the
   scanner only accepts a run of `name="value"` pairs, so the blocks above are
   illustrative and cannot be fed to `grammar fmt` as they stand.

   The tags line up per rule, not per alignment group. Two rules in one group each
   line up their own tags, since a tag annotates a production of one rule and
   lining it up against another rule's tag would say nothing.

   A rule with a single tag has nothing to line it up against, so it keeps the one
   space its tokens give it rather than being padded away from the production it
   annotates. Lines of a rule that hold no tag are left alone.

   A tag on a continuation line (see rule 5) takes part as well, since a tag closes
   the production of the line it is written on.

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
