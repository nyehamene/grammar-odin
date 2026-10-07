# Print nodes

Print ast nodes tree format and highlight invalid tokens.

- Implement `grammar print --ast <PATH>`.
- Add tests to parse the files in ../example.
- Preserve newlines and comments.


## Update nodes tree format

Update the output format to the following structure.

File
3:1    RuleDecl: token
3:9        Ident
3:9            AlternativeProduction
3:9                Ident: @import
3:16               GroupProduction
3:17                   StringLit: "token.grammar"
