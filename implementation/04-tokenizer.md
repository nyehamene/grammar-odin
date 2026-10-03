# Tokenizer

Scan input grammar files. If any error is found exit
with a non-zero exit code.

See ../grammar.txt for the valid tokens in the grammar.

- Implement `grammar check <PATH>`.
- Add tests that scans each file in ../example directory.

# Token

- Ident - alphanumeric. Ex `foo, b10, Foo,`
- String - double quoted string literal. Ex `"a string"`
- Regex - single quote. Ex `'[a-zA-Z]*'`
- External Ident - Ex `__string__, __Keyword__`
- Paren - Ex `()`
- Bracket - Ex `[]`
- Brace - Ex `{}`
- Pipe - Ex `|`
- Semicolon - Ex `;`
- Equal - Ex `=`
- Lt - Ex `<`
- Gt - Ex '>'
- Comment - Ex `// a comment`
- Tag - backtick delimited. Ex `` `name="Value"; another_name="100"` ``

A tag is scanned as one token: the whole run between the backticks, including
them. It holds one or more `ident "=" string` pairs separated by `;`, so a `;`
or a quote inside a value is part of that value rather than a separator. Like a
string it may not span a line, since the formatter buckets tokens by the line
they start on. A tag that does not hold that shape is reported as an invalid tag
literal, and one that is never closed as an unterminated tag literal; either way
a tag token is still produced so the parser keeps its place.
