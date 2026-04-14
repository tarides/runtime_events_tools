type t

val create : int -> t
val clear : t -> unit
val pos : t -> int
val available : t -> int
val bytes : t -> Bytes.t
val put_64 : t -> int64 -> unit
val put_string_padded : t -> string -> unit
val advance : t -> int -> unit
val flush : t -> out_channel -> unit

external put_raw_64_le : Bytes.t -> int -> int64 -> unit = "%caml_bytes_set64u"
  [@@noalloc]

external put_event_header :
  Bytes.t -> int ->
  int -> int -> int -> int -> int -> unit
  = "fxt_put_event_header_bytecode" "fxt_put_event_header_native" [@@noalloc]

external put_arg_header_i32 :
  Bytes.t -> int ->
  int -> int -> int -> unit
  = "fxt_put_arg_header_i32" [@@noalloc]

external put_arg_header_i64 :
  Bytes.t -> int ->
  int -> int -> unit
  = "fxt_put_arg_header_i64" [@@noalloc]
