package lsp

import "core:fmt"
import "core:io"
import "core:mem"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"

Frame :: struct {
	arena:   virtual.Arena,
	stdin:   io.Reader,
	logout:  io.Writer,
	headers: map[string]string,
}

Frame_init :: proc(f: ^Frame, stdin: io.Reader, logout: io.Writer) {
	assert(f != nil)
	err := virtual.arena_init_growing(&f.arena, 1 * mem.Megabyte)
	assert(err == nil)
	alloc := virtual.arena_allocator(&f.arena)
	f.headers = make(map[string]string, allocator = alloc)
	f.stdin = stdin
	f.logout = logout
}

Frame_destroy :: proc(f: ^Frame) {
	virtual.arena_free_all(&f.arena)
	alloc := virtual.arena_allocator(&f.arena)
	f.headers = make(map[string]string, allocator = alloc)
}

read_frame :: proc(frame: ^Frame) -> (buf: []byte, ok: bool) {
	read_frame_header(frame) or_return

	length, has_length := frame_content_length(frame)
	if !has_length {
		debug(frame, "frame does not contain Content-Length")
		return nil, false
	}
	if length < 0 {
		debug(frame, "frame has invalid Content-Length")
		return nil, false
	}

	alloc := virtual.arena_allocator(&frame.arena)

	buf = make([]byte, length, alloc)
	offset := 0

	if length == 0 {
		return buf, true
	}

	for offset < length {
		n, err := io.read(frame.stdin, buf[offset:])
		if n > 0 {
			offset += n
		}
		if err == .EOF {
			break
		}
		if err != nil {
			debug(frame, "failed to read frame data")
			return buf, false
		}
	}

	if offset < length {
		debugf(frame, "frame truncated: expected %v bytes, got %v", length, offset)
		return buf, false
	}

	return buf, true
}

read_frame_header :: proc(f: ^Frame) -> bool {
	alloc := virtual.arena_allocator(&f.arena)
	sb := strings.builder_make(alloc)

	buf: [1]byte
	got_header := false

	for {
		strings.builder_reset(&sb)

		line_end := false
		for !line_end {
			n, err := io.read(f.stdin, buf[:])
			if n > 0 {
				if buf[0] == '\n' {
					line_end = true
				} else {
					strings.write_byte(&sb, buf[0])
				}
			}
			if err != nil {
				debugf(f, "an error occurred while reading from stream: %v", err)
				return false
			}
		}

		line := strings.to_string(sb)
		if len(line) > 0 && line[len(line) - 1] == '\r' {
			line = line[:len(line) - 1]
		}

		if len(line) == 0 {
			if got_header {
				break
			}
			continue
		}
		got_header = true

		colon := strings.index_byte(line, ':')
		if colon < 0 {
			debugf(f, "malformed header line: %q", line)
			continue
		}
		name := strings.trim_space(line[:colon])
		value := strings.trim_space(line[colon + 1:])
		if name == "" {
			continue
		}
		f.headers[strings.clone(name, alloc)] = strings.clone(value, alloc)
	}

	return true
}

frame_content_length :: proc(f: ^Frame) -> (content_length: int, ok: bool) {
	assert(f != nil)

	// Header names are case-insensitive per the LSP/HTTP framing rules.
	value, found := f.headers["Content-Length"]
	if !found {
		for name, v in f.headers {
			if strings.equal_fold(name, "Content-Length") {
				value = v
				found = true
				break
			}
		}
	}
	if !found {
		return 0, false
	}

	length, l_ok := strconv.parse_int(value)
	if !l_ok {
		return 0, false
	}
	return length, true
}

write_request :: proc(w: io.Writer, id: Request_Id, method: string, params: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `{"jsonrpc":"2.0","id":`)
	strings.write_string(&sb, id)
	strings.write_string(&sb, `,"method":"`)
	strings.write_string(&sb, method)
	strings.write_string(&sb, `","params":`)
	strings.write_string(&sb, params)
	strings.write_string(&sb, `}`)

	msg := strings.to_string(sb)
	return write_frame(w, msg)
}

// write_notification writes a JSON-RPC notification with the given params.
write_notification :: proc(w: io.Writer, method: string, params: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `{"jsonrpc":"2.0","method":"`)
	strings.write_string(&sb, method)
	strings.write_string(&sb, `","params":`)
	strings.write_string(&sb, params)
	strings.write_string(&sb, `}`)

	msg := strings.to_string(sb)
	return write_frame(w, msg)
}

write_response :: proc(srv: ^Server, id: Request_Id, result: string) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `{"jsonrpc": "2.0", "id": `)
	strings.write_string(&sb, id)
	strings.write_string(&sb, `, "result":`)
	strings.write_string(&sb, result)
	strings.write_string(&sb, "}")

	msg := strings.to_string(sb)
	frame := write_frame(srv.stdout, msg)
	debugf(srv, "\033[35mresponse\033[0m: %s", frame)
}

write_frame :: proc(w: io.Writer, msg: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "Content-Length: %d\r\n\r\n%s", len(msg), msg)
	frame := strings.to_string(sb)
	io.write(w, transmute([]u8)frame)
	return frame
}
