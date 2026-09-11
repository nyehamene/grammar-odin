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

A rule is an identifier follow by one or more parameter, an equal (=) and a body terminated by semicolon (;).
The body is one or more productions.

```
rule1 = "no parameter";

rule1 a b = "a and b are parameters"

```

### Using a rule

Rules are non terminals. To use a rule that has no parameter in a production you just specify the name. Ex `my_rule`.
To use a rule that has parameters and passing in arguments in a production you surround the name and arguments within `<>`.
Ex. `<my_rule with three arguments>` here the name is `my_rule`, and `with`, `three`, and `arguments` are the arguments.
