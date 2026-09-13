package lsp

Session :: struct {}

public_diagnostics :: proc(srv: ^Server, uri: string) {
	doc, found := srv.documents[uri]
	if !found {
		return
	}


}
