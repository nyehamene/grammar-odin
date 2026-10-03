package token

import "core:strings"

// A tag is a backtick delimited run of `name "=" value` pairs separated by
// semicolons: `` `name="value"` `` or `` `name="value"; other="100"` ``. The
// scanner validates the shape and the formatter renders it back, so both share
// this one split.

// Tag_Pair is one `name = "value"` entry of a tag. name is the bare identifier
// text, value is the string literal with its quotes still attached, and pos is
// the offset of the name within the parsed body.
Tag_Pair :: struct {
	name:  string,
	value: string,
	pos:   int,
}

// parse_tag splits the body of a tag, the text between the backticks, into its
// pairs. Spaces are allowed around `=` and after `;`, and the value must be a
// non-empty double quoted string. ok is false when body is not a well formed
// list of pairs, in which case the pairs found so far are returned anyway: the
// caller owns pairs and must delete it either way. The pairs hold no memory of
// their own, since both fields alias body.
parse_tag :: proc(body: string) -> (pairs: [dynamic]Tag_Pair, ok: bool) {
	pairs = make([dynamic]Tag_Pair)

	i := 0
	skip_spaces(body, &i)
	if i >= len(body) do return pairs, false

	for {
		name_start := i
		if !scan_ident(body, &i) do return pairs, false
		name := body[name_start:i]

		skip_spaces(body, &i)
		if i >= len(body) || body[i] != '=' do return pairs, false
		i += 1

		skip_spaces(body, &i)
		value_start := i
		if !scan_quoted(body, &i) do return pairs, false
		value := body[value_start:i]

		append(&pairs, Tag_Pair{name = name, value = value, pos = name_start})

		skip_spaces(body, &i)
		if i >= len(body) do break
		if body[i] != ';' do return pairs, false
		i += 1
		skip_spaces(body, &i)
		// A trailing `;` names no pair.
		if i >= len(body) do return pairs, false
	}

	ok = true
	return
}

// write_tag renders pairs in the canonical spelling: no space around `=`, one
// space after each `;`, backticks around the whole run. The result is owned by
// the caller.
write_tag :: proc(builder: ^strings.Builder, pairs: []Tag_Pair) {
	strings.write_string(builder, "`")
	for pair, i in pairs {
		if i > 0 do strings.write_string(builder, "; ")
		strings.write_string(builder, pair.name)
		strings.write_string(builder, "=")
		strings.write_string(builder, pair.value)
	}
	strings.write_string(builder, "`")
}

// scan_ident advances i over an identifier and reports whether it found one.
scan_ident :: proc(body: string, i: ^int) -> bool {
	start := i^
	if i^ >= len(body) || !is_ident_start(body[i^]) do return false
	i^ += 1
	for i^ < len(body) && is_ident_part(body[i^]) {
		i^ += 1
	}
	return i^ > start
}

// scan_quoted advances i over a double quoted string, honouring a backslash
// escape of a quote, and reports whether it found one. The quotes are part of
// the span.
scan_quoted :: proc(body: string, i: ^int) -> bool {
	if i^ >= len(body) || body[i^] != '"' do return false
	i^ += 1
	for i^ < len(body) {
		ch := body[i^]
		if ch == '\\' {
			i^ += 2
			continue
		}
		i^ += 1
		if ch == '"' do return true
	}
	return false
}

skip_spaces :: proc(body: string, i: ^int) {
	for i^ < len(body) && is_space(body[i^]) {
		i^ += 1
	}
}