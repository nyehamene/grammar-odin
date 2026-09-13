# Language server

Language server implementation.

The language server protocol implementation code and API should be placed in 'server' directory.

## Implementation Plan

- [x] **1. `textDocument/hover`** (implemented in `cmd/lsp/hover.odin`)
    - [x] **Types**: `Hover`, `Marked_String`, and position parsing in `cmd/lsp/hover.odin`.
    - [x] **AST Position Logic**: `find_hit`/`find_hit_expr` in `cmd/lsp/find.odin` find the most specific token under an offset.
    - [x] **Handler**: `handleHover` uses the position logic to identify the node under the cursor.
    - [x] **Type Formatting**: The handler describes literals, directives, parameters, and resolves rule names, import bindings, and namespace members to their declaration locations.
    - [x] **Dispatcher**: `textDocument/hover` is wired in `cmd/lsp/server.odin`.
    - [x] **Test**: `test_lsp_hover` in `cmd/lsp/lsp_test.odin`.

- [x] **2. `textDocument/definition` (Go to Definition)** (implemented in `cmd/lsp/definition.odin`)
    - [x] **Types**: `Location` added in `cmd/lsp/definition.odin`.
    - [x] **Definition Logic**: `definition_for` resolves the identified symbol (rule, import binding, or namespace member) to its declaration file and offset using the `CompilationUnit` name/binding tables.
    - [x] **Handler**: `handleDefinition` uses `find_hit` for the AST position logic.
    - [x] **Dispatcher**: `textDocument/definition` is wired in `cmd/lsp/server.odin`.
    - [x] **Test**: `test_lsp_definition` in `cmd/lsp/lsp_test.odin`.

- [x] **3. `textDocument/references` (Find All References)** (implemented in `cmd/lsp/references.odin`)
    - [x] **Types**: The response is a list of `Location`.
    - [x] **Reference Finding Logic**: `reference_target` resolves the symbol to a namespace rule or file-local binding; `collect_rule_refs`/`collect_binding_refs` walk every open document's AST to find all usages (declaration, terms, calls, member accesses).
    - [x] **Handler**: `handleReferences` honors `context.includeDeclaration` and returns sorted, deduplicated locations.
    - [x] **Dispatcher**: `textDocument/references` is wired in `cmd/lsp/server.odin`.
    - [x] **Test**: `test_lsp_references` in `cmd/lsp/lsp_test.odin`.

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
