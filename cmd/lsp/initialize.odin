package lsp

import "core:encoding/json"
import "core:log"

Request_Id :: string

Client_Info :: struct {
	name:    string,
	version: string,
}

Server_Info :: struct {
	name:    string,
	version: string,
}

Text_Document_Sync_Kind :: enum {
	Full = 1,
}

Text_Document_Sync_Options :: struct {
	open_close: bool `json:"openClose"`,
	change:     Text_Document_Sync_Kind,
}

Diagnostic_Provider :: struct {
	inter_file_dependencies: bool `json:"interFileDependencies"`,
	workspace_diagnostics:   bool `json:"workspaceDiagnostics"`,
}

Server_Capabilities :: struct {
	text_document_sync:       Text_Document_Sync_Options `json:"textDocumentSync"`,
	position_encoding:        string `json:"positionEncoding"`,
	diagnostic_provider:      Diagnostic_Provider `json:"diagnosticProvider"`,
	semantic_tokens_provider: Semantic_Tokens_Options `json:"semanticTokensProvider"`,
}

Initialize_Result :: struct {
	capabilities: Server_Capabilities `json:"capabilities"`,
	server_info:  Server_Info `json:"serverInfo"`,
}

@(rodata)
server_info := Server_Info {
	name    = "grammar_ls",
	version = "0.1",
}

handle_initialize :: proc(srv: ^Server, id: Request_Id, req: json.Object) -> (ok: bool) {
	params := json_object(req, "params") or_return

	if client, ok := get_client_info(params); ok {
		if client_supports_semantic_tokens(srv, params) {
			debugf(
				srv,
				"message %s: client '%s' version %s supports semantic tokens",
				id,
				client.name,
				client.version,
			)
		}
	}

	result := create_initialize_result(srv)
	write_response(srv, id, string(result))
	return true
}

create_initialize_result :: proc(srv: ^Server) -> string {
	result: Initialize_Result
	result.server_info = server_info
	result.capabilities = Server_Capabilities {
		text_document_sync = Text_Document_Sync_Options{open_close = true, change = .Full},
		position_encoding = "utf-8",
		diagnostic_provider = Diagnostic_Provider {
			inter_file_dependencies = false,
			workspace_diagnostics = false,
		},
		semantic_tokens_provider = Semantic_Tokens_Options {
			legend = Semantic_Tokens_Legend {
				token_types = []string {
					"function",
					"parameter",
					"namespace",
					"property",
					"string",
					"variable",
					"operator",
				},
				token_modifiers = []string{},
			},
			full = true,
		},
	}

	result_str, err := json.marshal(result, allocator = context.temp_allocator)
	if err != nil {
		debugf(srv, "failed to marshal initialize_result to json%v", err)
		return ""
	}

	return string(result_str)
}

get_client_info :: proc(params: json.Object) -> (c: Client_Info, ok: bool) {
	client := json_object(params, "clientInfo") or_return
	c.name = json_string(client, "name") or_return

	if version, ok := json_string(client, "version"); ok {
		c.version = string(version)
	}
	return c, true
}

client_supports_semantic_tokens :: proc(srv: ^Server, params: json.Object) -> (ok: bool) {
	capabilities := json_object(params, "capabilities") or_return
	text_document := json_object(capabilities, "textDocument") or_return
	semantic_tokens := json_object(text_document, "semanticTokens") or_return
	return true
}
