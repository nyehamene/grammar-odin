# Tag

Add support for tags.

## Rules

1. A tag must be the last element in a production or alternative.

  Ex: Valid
  ```
  foo = a `name="value"`;
  bar = a b `name="value"`;

  alt = foo `name="Foo"`
      | bar `name="Bar"`
      ;
  ```

  A tag annotates the production it follows: it wraps the whole sequence rather
  than standing on its own or hanging off the last element (see rule 4). The tag
  adds no element of its own and carries no meaning: the production it annotates
  is checked, printed and resolved exactly as if it stood alone.

  Ex: Invalid
  ```
  bar = a `name="value"` b;
  ```

2. Tag inside a group/repetition/optional is invalid
   A tag inside a group/repetition/optional is not consider the last element
   in the production/alternative.

  Ex: Invalid
  ```
  bar = (a x `name="value"`);
  bar = [a x `name="value"`];
  bar = {a x `name="value"`};
  ```

  Ex: valid
  ```
  bar = (a x) `name="value"`;
  bar = [a x] `name="value"`;
  bar = {a x} `name="value"`;
  ```

  A call argument list is a group too, so this is invalid as well:
  ```
  bar = <baz a x `name="value"`>;
  ```

3. A tag as the only element in a rule body is invalid

   Ex:
  ```
  foo = `name="value"`;
  ```

4. A tag wraps the entire sequence not the last production in the sequence

   Ex:
   ```
   foo = a b c `name="value"`;
   ```

   The tag `name="value"` is assigned to the sequence `a b c`. Rather than being
   assigned to just `c`

   Each alternative is a production of its own, so each one is annotated
   separately:
   ```
   alt = a b `name="first"`
       | c d `name="second"`
       ;
   ```

5. A production carries one tag.

   A tag annotates a production, and a production is annotated once, so a second
   tag has nothing left to annotate:

   Ex: Invalid
   ```
   foo = a b `name="a"` `age="100"`;
   ```

   Use several pairs in one tag to say more than one thing about a production,
   as in `foo = a b `name="a"; age="100"`;`.

## Shape

A tag holds one or more `name="value"` pairs separated by `;`. Both halves of a
pair are fixed: the name is an identifier and the value is a string literal, so
a `;` or a quote inside a value is not a separator.

```
foo = a `name="value"`;
bar = a `name="a"; other="100"`;
```

Spaces are allowed around `=` and after `;` when reading, but the formatter
writes one spelling: no space around `=`, one space after each `;`.

```
bar = a `name="a"; other="100"`;
```

A malformed tag is a lexical error, reported once by the scanner, which still
yields a tag token so the parser keeps its place. A tag may not span a line,
for the same reason a string literal may not.

## Checklist

- [x] `token`: `.Tag` kind, `scan_tag`, and the shared `parse_tag`/`write_tag`
      split in `token/tag.odin`
- [x] `ast`: `Tagged_Expr` wrapping the annotated production, and one `Tag_Pair`
      per entry, each with its own position
- [x] `ast`: rules 1 to 5 enforced, with the diagnostic pointing at the tag
- [x] `check`: a tagged production yields the operand of the element it
      annotates, so tags change nothing semantically
- [x] `fmt`: canonical spelling, idempotent
- [x] `lsp`: references, hover, definition and signature help look through a tag;
      semantic tokens skip it
- [x] `example/tags.grammar`
