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
