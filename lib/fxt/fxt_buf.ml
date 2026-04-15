type t = { buf : Bytes.t; mutable pos : int; pos_end : int }

let create n =
  let n = (n + 7) land lnot 7 in
  { buf = Bytes.create n; pos = 0; pos_end = n }

let[@inline] clear t = t.pos <- 0
let[@inline] pos t = t.pos
let[@inline] available t = t.pos_end - t.pos

external put_raw_64_le : Bytes.t -> int -> int64 -> unit = "%caml_bytes_set64u"
[@@noalloc]

let[@inline always] put_64 t (v : int64) =
  let pos = t.pos in
  put_raw_64_le t.buf pos v;
  t.pos <- pos + 8

let put_string_padded t s =
  let len = String.length s in
  Bytes.blit_string s 0 t.buf t.pos len;
  t.pos <- t.pos + len;
  let pad = lnot (len - 1) land 7 in
  if pad > 0 then begin
    Bytes.fill t.buf t.pos pad '\000';
    t.pos <- t.pos + pad
  end

let[@inline] advance t n = t.pos <- t.pos + n

let flush t oc =
  output oc t.buf 0 t.pos;
  t.pos <- 0

let[@inline] bytes t = t.buf

(* Zero-allocation C stubs for packing FXT headers directly into the
   buffer without intermediate Int64 boxing. *)
external put_event_header :
  Bytes.t -> int -> int -> int -> int -> int -> int -> unit
  = "fxt_put_event_header_bytecode" "fxt_put_event_header_native"
[@@noalloc]

external put_arg_header_i32 : Bytes.t -> int -> int -> int -> int -> unit
  = "fxt_put_arg_header_i32"
[@@noalloc]

external put_arg_header_i64 : Bytes.t -> int -> int -> int -> unit
  = "fxt_put_arg_header_i64"
[@@noalloc]

external int64_div_to_decimal : Bytes.t -> int -> int64 -> int -> int
  = "fxt_int64_div_to_decimal"
[@@noalloc]
