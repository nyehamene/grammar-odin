# Language server

Language server implementation.

The language server protocol implementation code and API should be placed in 'server' directory.

## Implementation Plan

- [x] **1. `textDocument/hover`** (implemented in `cmd/lsp/hover.odin`)
    - [x] **Types**: `Hover`, `Marked_String`, and position parsing in `cmd/lsp/hover.odin`.
    - [x] **AST Position Logic**: `find_hit`/`find_hit_production` in `cmd/lsp/find.odin` find the most specific token under an offset.
    - [x] **Handler**: `handleHover` uses the position logic to identify the node under the cursor.
    - [x] **Type Formatting**: The handler describes literals, directives, parameters, and resolves rule names, import bindings, and namespace members to their declaration locations.
    - [x] **Dispatcher**: `textDocument/hover` is wired in `cmd/lsp/server.odin`.
    - [x] **Test**: `test_lsp_hover` in `cmd/lsp/lsp_test.odin`.

- [x] **2. `textDocument/definition` (Go to Definition)** (implemented in `cmd/lsp/definition.odin`)
    - [x] **Types**: `Location` added in `cmd/lsp/definition.odin`.
    - [x] **Definition Logic**: `definition_for` resolves the identified symbol (rule, import binding, or namespace member) to its declaration file and offset using the `CompilationUnit` name/binding tables. A namespace member is only resolved when it is exported, matching the checker.
    - [x] **Handler**: `handleDefinition` uses `find_hit` for the AST position logic.
    - [x] **Dispatcher**: `textDocument/definition` is wired in `cmd/lsp/server.odin`.
    - [x] **Test**: `test_lsp_definition` in `cmd/lsp/lsp_test.odin`.

A name in the source is resolved to one declaration, which is a rule for a bare
identifier and a proc of a particular arity for a call. `find_hit` records the
argument count of the call under the cursor in `Hit.arity`, which is what every
feature then resolves with, and the resolution itself goes through the checker's
exported resolvers so the server and the checker never disagree about what a name
is. A name may be a rule and procs at once, so a feature that means "this symbol"
has to say whether it means the rule, one proc, or the whole name: references and
document highlight follow one declaration, rename follows the name, and signature
help offers every proc of a name and marks the one the arguments pick.

- [x] **3. `textDocument/references` (Find All References)** (implemented in `cmd/lsp/references.odin`)
    - [x] **Types**: The response is a list of `Location`.
    - [x] **Reference Finding Logic**: `reference_target` resolves the symbol to a namespace rule or file-local binding; `collect_rule_refs`/`collect_binding_refs` walk every open document's AST to find all usages (declaration, terms, calls, member accesses).
    - [x] **Handler**: `handleReferences` honors `context.includeDeclaration` and returns sorted, deduplicated locations. References are matched by name and arity, so the references of one proc do not include the call sites of the others.
    - [x] **Dispatcher**: `textDocument/references` is wired in `cmd/lsp/server.odin`.
    - [x] **Test**: `test_lsp_references` in `cmd/lsp/lsp_test.odin`.

- [x] **4. `textDocument/documentSymbol`** (implemented in `cmd/lsp/documentsymbol.odin`)
    - [x] **Types**: `Document_Symbol` and `Symbol_Kind` added in `cmd/lsp/documentsymbol.odin`.
    - [x] **Handler**: `handleDocumentSymbol` returns the documents' rules, import bindings, and rule parameters as a symbol hierarchy. A proc is labelled with its parameter list (`foo(x, y)`) so the procs of one name are told apart.
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
    - [x] **Handlers**: `handle_prepare_rename` and `handle_rename` implemented in `cmd/lsp/rename.odin`. A rename is matched by name and moves every overload of it together, since the procs of a name are dispatched by arity and renaming one alone would break the others.
    - [x] **Logic**: Reuses `reference_target` and the `collect_*_refs` walkers (with `include_declaration`) to build a per-document `WorkspaceEdit`.
    - [x] **Dispatcher**: `textDocument/prepareRename` and `textDocument/rename` are wired in `cmd/lsp/server.odin`.
    - [x] **Test**: `test_lsp_rename` in `cmd/lsp/lsp_test.odin`.
    - [x] **Fix**: The frame use-after-free fix moved into `Frame_destroy` (recreates the headers map after freeing the arena).

- [x] **7. `textDocument/completion`** (implemented in `cmd/lsp/completion.odin`)
    - [x] **Types**: `Completion_Item`, `Completion_Item_Kind`, `Completion_List` added in `cmd/lsp/completion.odin`. An item also carries the `textEdit` to apply and the `insertTextFormat` saying how to read it, since the label is not what goes in the document.
    - [x] **Handler**: `handle_completion` implemented in `cmd/lsp/completion.odin`.
    - [x] **Logic**: `completion_prefix` extracts the identifier being typed (and an optional `binding.` receiver); suggestions are the shared namespace rules, file-local imports, and the exported members of an imported namespace. A local or private rule of another namespace is not offered, since the checker would reject a use of it.
    - [x] **Insertion**: a label is not what belongs in the document. A proc's label carries its parameter list, so that the procs of one name are told apart in the list, and `foo(x)` is not grammar, so what a completion inserts is carried separately in a `textEdit` over the typed prefix. A rule is completed by its name, and a proc by a call naming it: `<def ${1:x}>` outside a call, and `def ${1:x}` inside one, where the angle brackets are already typed. Whether the arguments carry tab stops depends on the client having asked for snippets in `initialize`, since one that cannot read a snippet would insert the `${1:x}` as text.
    - [x] **Dispatcher**: `textDocument/completion` is wired in `cmd/lsp/server.odin`.
    - [x] **Test**: `test_lsp_completion`, `test_lsp_completion_member_offers_only_exported_rules`, `test_lsp_completion_proc_inserts_a_call`, `test_lsp_completion_proc_without_snippet_support` and `test_lsp_completion_proc_tab_stop_per_argument` in `cmd/lsp/lsp_test.odin`.

- [x] **8. `textDocument/diagnostic` (Pull Diagnostics)** (implemented in `cmd/lsp/diagnostic.odin`)
    - [x] **Types**: `Diagnostic`, `Publish_Diagnostics_Params`, `Pull_Diagnostic_Result` in `cmd/lsp/diagnostic.odin`.
    - [x] **Handler**: `handle_text_document_diagnostic` implemented in `cmd/lsp/diagnostic.odin`.
    - [x] **Logic**: Runs the checker over the open documents through `index_documents` and returns the diagnostics. `severity_code` maps a checker `Error` to LSP `1` and a `Warning` to `2`, so an unused rule arrives as a warning rather than a failure.
    - [x] **Dispatcher**: `textDocument/diagnostic` is wired in `cmd/lsp/server.odin`.
    - [x] **Test**: `test_lsp_pull_diagnostic` and `test_lsp_did_open_publishes_diagnostics` in `cmd/lsp/lsp_test.odin`.

Push diagnostics (`textDocument/publishDiagnostics`) are published per namespace:
opening, changing or closing a document re-runs the checker over its directory
tree and pushes one notification per file, so cross-file errors such as a rule
redeclared in the namespace appear on the affected files and clear as soon as
the edit that fixed them lands. Files outside the namespace root, such as
imported namespaces, are not republished.

- [x] **9. `textDocument/documentHighlight`** (implemented in `cmd/lsp/document_highlight.odin`)
    - [x] **Types**: `Document_Highlight` and `Document_Highlight_Kind` added in `cmd/lsp/document_highlight.odin`.
    - [x] **Handler**: `handle_document_highlight` implemented in `cmd/lsp/document_highlight.odin`.
    - [x] **Logic**: Reuses `reference_target` and the `collect_*_refs` walkers for the cursor's document.
    - [x] **Dispatcher**: `textDocument/documentHighlight` is wired in `cmd/lsp/server.odin`.
    - [x] **Test**: `test_lsp_document_highlight` in `cmd/lsp/lsp_test.odin`.

- [x] **10. `textDocument/semanticTokens`** (implemented in `cmd/lsp/semantic_tokens.odin`)
    - [x] **Types**: `Semantic_Tokens`, `Semantic_Tokens_Legend`, `Semantic_Tokens_Options` added in `cmd/lsp/semantic_tokens.odin`.
    - [x] **Logic**: Walks the AST to classify identifiers (rules, parameters, bindings, members) and maps literal/operator tokens to legend types.
    - [x] **Handler**: `handle_semantic_tokens_full` implemented in `cmd/lsp/semantic_tokens.odin`, emitting delta-encoded quintuples.
    - [x] **Dispatcher**: `textDocument/semanticTokens/full` is wired in `cmd/lsp/server.odin`.
    - [x] **Capabilities**: `semanticTokensProvider` with the token legend is advertised during initialize.
    - [x] **Test**: `test_lsp_semantic_tokens` in `cmd/lsp/lsp_test.odin`.

- [x] **11. `textDocument/documentLink`** (implemented in `cmd/lsp/documentlink.odin`)
    - [x] **Types**: `DocumentLink` with `range` and `target` in `cmd/lsp/documentlink.odin`.
    - [x] **Handler**: `handle_document_link` in `cmd/lsp/documentlink.odin`.
    - [x] **Logic**: Generate links for `@import` bindings, resolving the relative path against the importing file's directory (mirroring `check`'s `.grammar` extension fallback).
    - [x] **Dispatcher**: Wire up `textDocument/documentLink` in `server.odin`.
    - [x] **Test**: `test_lsp_document_link` in `cmd/lsp/lsp_test.odin`.
