package lsp

import "core:strconv"
import "core:strings"

// Position is a zero-based line/character offset in an LSP document.
// The server negotiates UTF-8 positions, so character counts bytes.
Position :: struct {
	line:      int,
	character: int,
}

// Range is a half-open span between two positions.
Range :: struct {
	start: Position,
	end:   Position,
}

// Text_Edit is declared in rename.odin. A completion uses it to say exactly which
// typed characters are replaced, rather than leaving the client to guess the word under
// the cursor by its own rules.

// position_at_offset returns the zero-based LSP position of offset within src.
position_at_offset :: proc(src: string, offset: int) -> Position {
	off := clamp(offset, 0, len(src))
	line := 0
	character := 0
	for i in 0 ..< off {
		if src[i] == '\n' {
			line += 1
			character = 0
		} else {
			character += 1
		}
	}
	return Position{line = line, character = character}
}

// offset_at_position returns the byte offset of pos within src, clamped to the
// end of src. The search is line/column based; an out-of-range column is
// clamped to the end of its line.
offset_at_position :: proc(src: string, pos: Position) -> int {
	line := 0
	character := 0
	for i in 0 ..< len(src) {
		if line == pos.line {
			if character == pos.character {
				return i
			}
			if src[i] == '\n' {
				return i
			}
			character += 1
		} else if src[i] == '\n' {
			line += 1
			character = 0
		}
	}
	return len(src)
}

// word_extent returns the length of the identifier run starting at offset.
word_extent :: proc(src: string, offset: int) -> int {
	if offset < 0 || offset >= len(src) do return 0
	end := offset
	for end < len(src) && is_ident_byte(src[end]) {
		end += 1
	}
	return end - offset
}

is_ident_byte :: proc(b: byte) -> bool {
	return b == '_' ||
		b >= 'a' && b <= 'z' ||
		b >= 'A' && b <= 'Z' ||
		b >= '0' && b <= '9'
}

// uri_to_path converts a file:// URI to a filesystem path. The returned
// string is owned by the caller.
uri_to_path :: proc(uri: string) -> (path: string, ok: bool) {
	if !strings.has_prefix(uri, "file://") do return "", false
	p := uri[len("file://"):]

	// After "file://", a path starts with '/'. An authority form such as
	// file://host/path is treated as a local path starting at the first '/'.
	if len(p) > 0 && p[0] != '/' {
		slash := strings.index_byte(p, '/')
		if slash < 0 do return "", false
		p = p[slash:]
	}

	return percent_decode(p), true
}

// path_to_uri converts a filesystem path to a file:// URI. The returned
// string is owned by the caller.
path_to_uri :: proc(path: string) -> string {
	sb := strings.builder_make(context.allocator)
	strings.write_string(&sb, "file://")
	for i in 0 ..< len(path) {
		b := path[i]
		switch b {
		case '%':
			strings.write_string(&sb, "%25")
		case '#':
			strings.write_string(&sb, "%23")
		case '?':
			strings.write_string(&sb, "%3F")
		case ' ':
			strings.write_string(&sb, "%20")
		case:
			if b < 0x20 || b >= 0x7f {
				write_percent_byte(&sb, b)
			} else {
				strings.write_byte(&sb, b)
			}
		}
	}
	return strings.to_string(sb)
}

percent_decode :: proc(s: string) -> (res: string) {
	if !strings.contains(s, "%") do return strings.clone(s)

	sb := strings.builder_make(context.allocator)
	for i := 0; i < len(s); {
		if s[i] == '%' && i + 2 < len(s) {
			if b, ok := strconv.parse_int(s[i + 1:i + 3], 16); ok {
				strings.write_byte(&sb, u8(b))
				i += 3
				continue
			}
		}
		strings.write_byte(&sb, s[i])
		i += 1
	}
	return strings.to_string(sb)
}

write_percent_byte :: proc(sb: ^strings.Builder, b: byte) {
	hex := "0123456789ABCDEF"
	strings.write_string(sb, "%")
	strings.write_byte(sb, hex[b >> 4])
	strings.write_byte(sb, hex[b & 0x0f])
}