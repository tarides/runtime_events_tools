type t

type thread = {
  pid : int64;
  tid : int64;
}

val create : out_channel -> t
val close : t -> unit

val duration_begin : t -> thread:thread -> name:string -> ts:int64 -> unit
val duration_end : t -> thread:thread -> name:string -> ts:int64 -> unit
val instant : t -> thread:thread -> name:string -> ts:int64 -> unit
val counter : t -> thread:thread -> name:string -> ts:int64 -> value:int -> unit
