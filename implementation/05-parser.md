# Parser

Parse input files and produces and AST. If an error is found
the program report the errors and exit with a non-zero exit code.

The implementation should provide proper error reporting.

See ../grammar.txt for for details.

- Implement a recursive descent parser that is invoked with
  `grammar check <PATH>`.

- The parser should get input tokens from the tokenizer implemented
  previously.

- The parser should return an ast node for each input file.

# Ast

see ../grammar.txt

- Binding
- Rule
- Terminal
- Non_Terminal
- Group - Ex `(a b)`
- Repetition - Ex `{ a }` zero or more
- Optional - Ex `[ a ]` zero or one
- Member_Access - Ex `foo.bar`

## Rule

A rule is an identifier follow by zero or more parameters, an equal (=) and a body terminated by semicolon (;).
The body is one production.

```
rule1 = "no parameter";

rule1 a b = "a and b are parameters"

```

### Using a rule

Rules are non terminals. To use a rule that has no parameter in a production you just specify the name. Ex `my_rule`.
To use a rule that has parameters and passing in arguments in a production you surround the name and arguments within `<>`.
Ex. `<my_rule with three arguments>` here the name is `my_rule`, and `with`, `three`, and `arguments` are the arguments.

## Comment: Parser should handle comments inside rule body.

```
rule1 = a // comment
      | b // comment
      ;


rule2 = a // comment
      ;
```

A comment inside a declaration is trivia: it may sit between the parameters,
between any two tokens of the body, or after the terminating semicolon. It is
consumed by the parser and does not reach the AST, so it resolves as no name,
counts as no call argument, and hides nothing. A comment that precedes a
declaration still introduces it and is kept as a comment group, since that is
what the formatter and the language server print.

## Tag

See 11-tag.md for the rules and `../grammar.txt` for the shape.

A tag annotates the production it follows, so it wraps the whole sequence instead
of standing on its own.

```
foo = a `name="value"`;   // Tagged_Expr { expr = a, tag = [name="value"] }
bar = a b `name="value"`; // Tagged_Expr { expr = Sequence_Expr { a, b }, tag }
```

`Tagged_Expr` holds the annotated production and one entry per `name="value"`
pair, each with its own position so a diagnostic can point at it. The wrapper
reports the position of the production it annotates, not that of the tag written
after it. A tag changes nothing about the production it annotates: the checker
produces the same operand for `a b `name="value"`` as for `a b`, and the language
server resolves every element of it as if the tag were not written.

The parser rejects a tag that annotates nothing (a body that is only a tag), one
that is not the last element of its production or alternative, a second tag on a
production that already carries one, and one nested inside a group, a repetition,
an optional or a call argument list, since such a tag annotates an inner
production rather than the rule's.

```
foo = `name="value"`;              // error: a tag must annotate a production element
bar = a `name="value"` b;          // error: a tag must be the last element in a production
baz = ( a x `name="value"` );      // error: a tag may not appear inside ...
qux = ( a x ) `name="value"`;      // valid: the tag annotates the group
quux = a b `name="v"` `age="1"`;   // error: a production may carry only one tag
```
