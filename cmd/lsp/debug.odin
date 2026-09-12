package lsp

import "core:fmt"
import "core:io"
import "core:path/filepath"

debug :: proc {
	debug_server,
	debug_frame,
	debug_writer,
}

debugf :: proc {
	debugf_server,
	debugf_frame,
	debugf_writer,
}

debug_server :: proc(srv: ^Server, msg: string, loc := #caller_location) {
	debug_writer(srv.logout, msg, loc)
}

debugf_server :: proc(srv: ^Server, format: string, args: ..any, loc := #caller_location) {
	debugf_writer(srv.logout, format, args = args, loc = loc)
}

debug_frame :: proc(f: ^Frame, msg: string, loc := #caller_location) {
	debug_writer(f.logout, msg, loc)
}

debugf_frame :: proc(f: ^Frame, format: string, args: ..any, loc := #caller_location) {
	debugf_writer(f.logout, format, args = args, loc = loc)
}

debugf_writer :: proc(w: io.Writer, format: string, args: ..any, loc := #caller_location) {
	msg := fmt.tprintf(format, args = args)
	debug_writer(w, msg, loc)
}

debug_writer :: proc(w: io.Writer, msg: string, loc := #caller_location) {
	file := filepath.base(loc.file_path)
	fmt.wprintfln(
		w,
		"%s:%d:%d \033[32m%v\033[0m %s",
		file,
		loc.line,
		loc.column,
		loc.procedure,
		msg,
	)
}
