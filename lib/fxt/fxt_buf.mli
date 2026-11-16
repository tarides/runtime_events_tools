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
val put_event_header : Bytes.t -> int -> int -> int -> int -> int -> int -> unit
val put_arg_header_i32 : Bytes.t -> int -> int -> int -> int -> unit
val put_arg_header_i64 : Bytes.t -> int -> int -> int -> unit
