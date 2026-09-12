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

Server_Capabilities :: struct {}

Initialize_Result :: struct {
	capabilities: Server_Capabilities `json:"capabilities"`,
	server_info:  Server_Info `json:"serverInfo"`,
}

@(rodata)
server_info := Server_Info {
	name    = "grammar_ls",
	version = "0.1",
}

@(rodata)
capabilities := Server_Capabilities{}

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

	result: Initialize_Result
	result.server_info = server_info
	result.capabilities = capabilities

	result_str, err := json.marshal(result, allocator = context.temp_allocator)
	if err != nil {
		debugf(srv, "failed to marshal initialize_result to json%v", err)
		return false
	}

	resp := write_response(srv.stdout, id, string(result_str))
	debug(srv, resp)
	return true
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
