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
	length := frame_content_length(frame)

	if length < 0 {
		debug(frame, "frame does not contain Content-Length")
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

	return buf, true
}

read_frame_header :: proc(f: ^Frame) -> bool {
	State :: enum {
		Header_Key,
		Header_Value,
		Seperator,
	}

	expect :: proc(b, value: byte) -> bool {
		return b == value
	}

	buf: [1]byte
	header_name: string
	state: State

	separator := 0
	state = .Header_Key

	alloc := virtual.arena_allocator(&f.arena)
	sb := strings.builder_make(alloc)

	for separator < 2 {
		n, err := io.read(f.stdin, buf[:])

		if n > 0 {
			b := buf[0]

			switch state {
			case .Header_Key:
				if b == '\r' {
					state = .Seperator
					continue
				}
				if b == ':' {
					continue
				}
				if b == ' ' {
					state = .Header_Value
					header_name = strings.to_string(sb)
					header_name = clone_string(&f.arena, header_name)
					strings.builder_reset(&sb)
					continue
				}
				separator = 0
				strings.write_byte(&sb, b)

			case .Header_Value:
				if b == ' ' {
					continue
				}
				if b == '\r' {
					state = .Seperator
					header_value := strings.to_string(sb)
					header_value = clone_string(&f.arena, header_value)
					f.headers[header_name] = header_value
					header_name = ""
					strings.builder_reset(&sb)
					continue
				}
				strings.write_byte(&sb, b)

			case .Seperator:
				if !expect(b, '\n') {
					debugf(f, "unexpected char in header separator: %v", b)
					return false
				}
				state = .Header_Key
				separator += 1
			}
		}
		if err != nil {
			debugf(f, "an error occurred while reading from stream: %v", err)
			return false
		}
	}

	return true
}

frame_content_length :: proc(f: ^Frame) -> int {
	assert(f != nil)
	content_length, ok := f.headers["Content-Length"]
	if !ok {
		return 0
	}
	length, l_ok := strconv.parse_int(content_length)
	if !l_ok {
		return 0
	}
	return length
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

write_response :: proc(w: io.Writer, id: Request_Id, result: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `{"jsonrpc": "2.0", "id": `)
	strings.write_string(&sb, id)
	strings.write_string(&sb, `, "result":`)
	strings.write_string(&sb, result)
	strings.write_string(&sb, "}")

	msg := strings.to_string(sb)
	return write_frame(w, msg)
}

write_frame :: proc(w: io.Writer, msg: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "Content-Length: %d\r\n\r\n%s", len(msg), msg)
	frame := strings.to_string(sb)
	fmt.wprintln(w, frame)
	return frame
}
