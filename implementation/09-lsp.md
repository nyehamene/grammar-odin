# Language server

Language server implementation.

The language server protocol implementation code and API should be placed in 'server' directory.

## Implementation Plan

- [ ] **1. `textDocument/hover`**
    - [ ] **Types**: Add `HoverParams` and `Hover` response types to `server/types.odin`.
    - [ ] **AST Position Logic**: Create a new helper function to find the `ast.Node` at a specific character offset. This will likely involve a new AST visitor.
    - [ ] **Handler**: Implement `handleHover` in `server/hover.odin`, which will use the position logic to find the node under the cursor.
    - [ ] **Type Formatting**: Use the `checker.typeOf` method to get the type of the identified node and format it into a user-friendly string.
    - [ ] **Dispatcher**: Wire up the `textDocument/hover` method in `server.odin`'s request handler.
    - [ ] **Test**: Add an integration test for the hover feature. (See `server/hover_test.odin`)

- [ ] **2. `textDocument/definition` (Go to Definition)**
    - [ ] **Types**: Add `DefinitionParams` and `Location` types to `server/types.odin`.
    - [ ] **Definition Logic**: Create a function that, given an `ast.Ident` node, finds its declaration (either in the current file or an imported one via the `CompilationUnit`).
    - [ ] **Handler**: Implement `handleDefinition` in `server/definition.odin` to use the AST position logic and the new definition logic.
    - [ ] **Dispatcher**: Wire up `textDocument/definition` in `server.odin`.
    - [ ] **Test**: Add an integration test for "Go to Definition." (See `server/definition_test.odin`)

- [ ] **3. `textDocument/references` (Find All References)**
    - [ ] **Types**: Add `ReferenceParams` to `server/types.odin`. The response is a `[]Location`.
    - [ ] **Reference Finding Logic**: Create a function that first finds a symbol's declaration, then traverses the AST of all documents in the `CompilationUnit` to find all usages.
    - [ ] **Handler**: Implement `handleReferences` in `server/references.odin`.
    - [ ] **Dispatcher**: Wire up `textDocument/references` in `server.odin`.
    - [ ] **Test**: Add an integration test for "Find All References." (See `server/references_test.odin`)

- [ ] **4. `textDocument/documentSymbol`**
    - [ ] **Types**: Add `DocumentSymbolParams`, `DocumentSymbol`, and `SymbolKind` to `server/types.odin`.
    - [ ] **Handler**: Implement `handleDocumentSymbol` in `server/documentsymbol.odin`.
    - [ ] **Logic**: Traverse the top-level declarations of a document's AST to build a list of symbols.
    - [ ] **Dispatcher**: Wire up `textDocument/documentSymbol` in `server.odin`.
    - [ ] **Test**: Add an integration test for document symbols. (See `server/document_symbol_test.odin`)

- [ ] **5. `workspace/symbol`**
    - [ ] **Types**: Add `WorkspaceSymbolParams` and `SymbolInformation` to `server/types.odin`.
    - [ ] **Handler**: Implement `handleWorkspaceSymbol` in `server/workspace_symbol.odin`.
    - [ ] **Logic**: Iterate through all files in the `CompilationUnit`, find symbols matching the query, and return them as a list of `SymbolInformation`.
    - [ ] **Dispatcher**: Wire up `workspace/symbol` in `server.odin`.
    - [ ] **Test**: Add an integration test for workspace symbols. (See `server/workspace_symbol_test.odin`)

- [ ] **6. `textDocument/rename`**
    - [ ] **Types**: Add `RenameParams` and `WorkspaceEdit` to `server/types.odin`.
    - [ ] **Handlers**: Implement `handlePrepareRename` and `handleRename` in `server/rename.odin`.
    - [ ] **Logic**: Use the "Find All References" logic to get all locations of a symbol and create a `WorkspaceEdit` containing `TextEdit`s to perform the rename.
    - [ ] **Dispatcher**: Wire up `textDocument/prepareRename` and `textDocument/rename` in `server.odin`.
    - [ ] **Test**: Add an integration test for the rename feature. (See `server/rename_test.odin`)

- [ ] **7. `textDocument/completion`**
    - [ ] **Types**: Add `CompletionParams`, `CompletionItem`, `CompletionList` to `server/types.odin`.
    - [ ] **Handler**: Implement `handleCompletion` in `server/completion.odin`.
    - [ ] **Logic**: Provide completions for rule names, binding references, package members, and import paths.
    - [ ] **Dispatcher**: Wire up `textDocument/completion` in `server.odin`.
    - [ ] **Test**: Add an integration test for completion. (See `server/completion_test.odin`)

- [ ] **8. `textDocument/diagnostic` (Pull Diagnostics)**
    - [ ] **Types**: Add diagnostic-related types to `server/types.odin`.
    - [ ] **Handler**: Implement `handleTextDocumentDiagnostic` in `server/diagnostics.odin`.
    - [ ] **Logic**: Call the checker and return diagnostics.
    - [ ] **Dispatcher**: Wire up `textDocument/diagnostic` in `server.odin`.
    - [ ] **Test**: Add an integration test for pull diagnostics. (See `server/diagnostics_test.odin`)

- [ ] **9. `textDocument/documentHighlight`**
    - [ ] **Types**: Add `DocumentHighlightParams` and `DocumentHighlight` to `server/types.odin`.
    - [ ] **Handler**: Implement `handleDocumentHighlight` in `server/document_highlight.odin`.
    - [ ] **Logic**: Find all references to the symbol at the cursor position.
    - [ ] **Dispatcher**: Wire up `textDocument/documentHighlight` in `server.odin`.
    - [ ] **Test**: Add an integration test for document highlight. (See `server/document_highlight_test.odin`)

- [ ] **10. `textDocument/semanticTokens`**
    - [ ] **Types**: Add `SemanticTokensParams`, `SemanticTokens`, `SemanticTokensPartialResult`, `SemanticTokenTypes`, and `SemanticTokenModifiers` to `server/types.odin`.
    - [ ] **Lexer/Parser Integration**: Ensure that the lexer and parser can provide sufficient information (e.g., token types, modifiers, ranges) to accurately categorize semantic tokens.
    - [ ] **Semantic Token Logic**: Implement a visitor or a traversal mechanism over the AST to identify and categorize all relevant tokens (e.g., keywords, identifiers, types, operators) and their modifiers.
    - [ ] **Handler**: Implement `handleSemanticTokensFull` (and potentially `handleSemanticTokensRange`) in `server/semantic_tokens.odin`. This handler will use the logic to produce the `SemanticTokens` response.
    - [ ] **Dispatcher**: Wire up `textDocument/semanticTokens/full` (and `textDocument/semanticTokens/range` if implemented) in `server.odin`.
    - [ ] **Test**: Add an integration test for semantic tokens. (See `server/semantic_tokens_test.odin`)

- [ ] **11. `textDocument/documentLink`**
    - [ ] **Types**: Add `DocumentLinkParams` and `DocumentLink` to `server/types.odin`.
    - [ ] **Handler**: Implement `handleDocumentLink` in `server/documentlink.odin`.
    - [ ] **Logic**: Generate links for `@import` and `@package` directives.
    - [ ] **Dispatcher**: Wire up `textDocument/documentLink` in `server.odin`.
    - [ ] **Test**: Add an integration test for document links. (See `server/document_link_test.odin`)
