type kind = ..
type kind += SpanBegin | SpanEnd | Instant | Counter of int
type t = { ring_id : int; ts : int64; name : string; kind : kind }
