package lsp

import "core:encoding/json"

import "../../ast"
import "../../token"

// Symbol_Kind mirrors the LSP DocumentSymbolKind enum values.
Symbol_Kind :: enum {
	File           = 1,
	Module         = 2,
	Namespace      = 3,
	Package        = 4,
	Class          = 5,
	Method         = 6,
	Property       = 7,
	Field          = 8,
	Constructor    = 9,
	Enum           = 10,
	Interface      = 11,
	Function       = 12,
	Variable       = 13,
	Constant       = 14,
	String         = 15,
	Number         = 16,
	Boolean        = 17,
	Array          = 18,
	Object         = 19,
	Key            = 20,
	Null           = 21,
	Enum_Member    = 22,
	Struct         = 23,
	Event          = 24,
	Operator       = 25,
	Type_Parameter = 26,
}

// Document_Symbol mirrors the LSP DocumentSymbol object.
Document_Symbol :: struct {
	name:           string,
	kind:           Symbol_Kind,
	range:          Range,
	selection_range: Range `json:"selectionRange"`,
	children:       []Document_Symbol,
}

// handle_document_symbol implements textDocument/documentSymbol, returning the
// rules and import bindings of the document as a hierarchy of symbols.
handle_document_symbol :: proc(srv: ^Server, id: Request_Id, obj: json.Object) -> (ok: bool) {
	params := json_object(obj, "params") or_return
	text_doc := json_object(params, "textDocument") or_return
	uri := json_string(text_doc, "uri") or_return

	doc, found := srv.documents[uri]
	if !found {
		write_response(srv.stdout, id, "[]")
		return true
	}

	symbols := document_symbols(doc)
	defer {
		for s in symbols {
			delete(s.children)
		}
		delete(symbols)
	}

	buf, err := json.marshal(symbols, allocator = context.temp_allocator)
	if err != nil {
		debugf(srv, "failed to marshal document symbols: %v", err)
		return false
	}

	frame := write_response(srv.stdout, id, string(buf))
	debug(srv, frame)
	return true
}

// document_symbols builds the symbol hierarchy of an open document. Rules are
// Functions with their parameters as children; import bindings are
// Namespaces. Ranges are approximate: a declaration spans from its first token
// to just before the next declaration.
document_symbols :: proc(doc: ^Document) -> [dynamic]Document_Symbol {
	symbols := make([dynamic]Document_Symbol)

	tokens, lex_errors := token.scan(doc.text)
	defer delete(tokens)
	defer delete(lex_errors)
	file, parse_errors := ast.parse_file(doc.text, tokens[:])
	defer ast.destroy_file(&file)
	defer delete(parse_errors)

	for i in 0 ..< len(file.decls) {
		next_pos := len(doc.text)
		if i + 1 < len(file.decls) {
			next_pos = ast.decl_pos(file.decls[i + 1])
		}
		start := position_at_offset(doc.text, ast.decl_pos(file.decls[i]))
		end := position_at_offset(doc.text, next_pos)
		decl_range := Range{start = start, end = end}

		#partial switch d in file.decls[i] {
		case ast.Rule_Decl:
			selection := Range{
				start = position_at_offset(doc.text, d.name.pos),
				end   = position_at_offset(doc.text, d.name.pos + len(d.name.name)),
			}
			children := make([]Document_Symbol, len(d.params))
			for p, j in d.params {
				param_range := Range{
					start = position_at_offset(doc.text, p.pos),
					end   = position_at_offset(doc.text, p.pos + len(p.name)),
				}
				children[j] = Document_Symbol{
					name            = p.name,
					kind            = .Variable,
					range           = param_range,
					selection_range = param_range,
				}
			}
			append(&symbols, Document_Symbol{
				name            = d.name.name,
				kind            = .Function,
				range           = decl_range,
				selection_range = selection,
				children        = children,
			})
		case ast.Binding_Decl:
			selection := Range{
				start = position_at_offset(doc.text, d.name.pos),
				end   = position_at_offset(doc.text, d.name.pos + len(d.name.name)),
			}
			append(&symbols, Document_Symbol{
				name            = d.name.name,
				kind            = .Namespace,
				range           = decl_range,
				selection_range = selection,
			})
		case ast.Comment_Group:
		}
	}

	return symbols
}