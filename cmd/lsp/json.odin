package lsp

import "core:encoding/json"
import "core:fmt"

json_object :: proc(obj: json.Object, key: string) -> (res: json.Object, ok: bool) {
	value := obj[key] or_return
	res = value.(json.Object) or_return
	return res, true
}

json_string :: proc(obj: json.Object, key: string) -> (json.String, bool) {
	v, found := obj[key]
	if !found {
		return "", false
	}
	s, s_ok := v.(json.String)
	if !s_ok {
		return "", false
	}
	return s, true
}

json_int :: proc(obj: json.Object, key: string) -> (json.Integer, bool) {
	v, found := obj[key]
	if !found {
		return 0, false
	}
	#partial switch q in v {
	case json.Integer:
		return q, true
	case json.Float:
		return json.Integer(q), true
	}
	return 0, false
}
