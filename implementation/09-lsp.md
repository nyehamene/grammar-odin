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

- [x] **4. `textDocument/documentSymbol`** (implemented in `cmd/lsp/documentsymbol.odin`)
    - [x] **Types**: `Document_Symbol` and `Symbol_Kind` added in `cmd/lsp/documentsymbol.odin`.
    - [x] **Handler**: `handleDocumentSymbol` returns the documents' rules, import bindings, and rule parameters as a symbol hierarchy.
    - [x] **Logic**: Walks the top-level declarations of a document's AST.
    - [x] **Dispatcher**: `textDocument/documentSymbol` is wired in `cmd/lsp/server.odin`.
    - [x] **Test**: `test_lsp_document_symbol` in `cmd/lsp/lsp_test.odin`.

- [x] **5. `workspace/symbol`** (implemented in `cmd/lsp/workspace_symbol.odin`)
    - [x] **Types**: `Symbol_Information` added in `cmd/lsp/workspace_symbol.odin`.
    - [x] **Handler**: `handle_workspace_symbol` implemented in `cmd/lsp/workspace_symbol.odin`.
    - [x] **Logic**: Iterates all files in the compilation unit, matches symbol names against the query, and returns `SymbolInformation` results sorted by name and location.
    - [x] **Dispatcher**: `workspace/symbol` is wired in `cmd/lsp/server.odin`.
    - [x] **Test**: `test_lsp_workspace_symbol` in `cmd/lsp/lsp_test.odin`.
    - [x] **Fix**: Intermittent parallel-test segfault fixed in `cmd/lsp/lsp.odin` (re-init frame headers map before each frame read).

- [x] **6. `textDocument/rename`** (implemented in `cmd/lsp/rename.odin`)
    - [x] **Types**: `Text_Edit`, `Workspace_Edit`, `Prepare_Rename_Result` added in `cmd/lsp/rename.odin`.
    - [x] **Handlers**: `handle_prepare_rename` and `handle_rename` implemented in `cmd/lsp/rename.odin`.
    - [x] **Logic**: Reuses `reference_target` and the `collect_*_refs` walkers (with `include_declaration`) to build a per-document `WorkspaceEdit`.
    - [x] **Dispatcher**: `textDocument/prepareRename` and `textDocument/rename` are wired in `cmd/lsp/server.odin`.
    - [x] **Test**: `test_lsp_rename` in `cmd/lsp/lsp_test.odin`.
    - [x] **Fix**: The frame use-after-free fix moved into `Frame_destroy` (recreates the headers map after freeing the arena).

- [x] **7. `textDocument/completion`** (implemented in `cmd/lsp/completion.odin`)
    - [x] **Types**: `Completion_Item`, `Completion_Item_Kind`, `Completion_List` added in `cmd/lsp/completion.odin`.
    - [x] **Handler**: `handle_completion` implemented in `cmd/lsp/completion.odin`.
    - [x] **Logic**: `completion_prefix` extracts the identifier being typed (and an optional `binding.` receiver); suggestions are the shared namespace rules, file-local imports, and the members of an imported namespace.
    - [x] **Dispatcher**: `textDocument/completion` is wired in `cmd/lsp/server.odin`.
    - [x] **Test**: `test_lsp_completion` and `test_lsp_completion_member` in `cmd/lsp/lsp_test.odin`.

- [x] **8. `textDocument/diagnostic` (Pull Diagnostics)** (implemented in `cmd/lsp/diagnostic.odin`)
    - [x] **Types**: `Diagnostic`, `Publish_Diagnostics_Params`, `Pull_Diagnostic_Result` in `cmd/lsp/diagnostic.odin`.
    - [x] **Handler**: `handle_text_document_diagnostic` implemented in `cmd/lsp/diagnostic.odin`.
    - [x] **Logic**: Runs the checker over the open documents through `index_documents` and returns the diagnostics.
    - [x] **Dispatcher**: `textDocument/diagnostic` is wired in `cmd/lsp/server.odin`.
    - [x] **Test**: `test_lsp_pull_diagnostic` and `test_lsp_did_open_publishes_diagnostics` in `cmd/lsp/lsp_test.odin`.

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
