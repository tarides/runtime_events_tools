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

(* Pack an FXT event header and write it directly into a Bytes.t buffer.
   All arguments are unboxed/untagged to avoid Int64 allocation.

   Layout (64 bits):
     bits  0-3:  record type (always 4 for events)
     bits  4-15: size in words
     bits 16-19: event type (0=instant, 1=counter, 2=begin, 3=end)
     bits 20-23: number of arguments
     bits 24-31: thread ref index (0 for inline)
     bits 48-63: name string ref
*)
let[@inline] put_event_header buf pos size event_ty n_args thread_ref name_ref =
  put_raw_64_le buf pos
    Int64.(
      logor 4L (* record type = event *)
        (logor
           (shift_left (of_int size) 4)
           (logor
              (shift_left (of_int event_ty) 16)
              (logor
                 (shift_left (of_int n_args) 20)
                 (logor
                    (shift_left (of_int thread_ref) 24)
                    (shift_left (of_int name_ref) 48))))))

(* Pack an FXT argument header for an int32 argument and write it.
   The int32 value is packed into the upper 32 bits of the header word.

   Layout (64 bits):
     bits  0-3:  argument type (1 = int32)
     bits  4-15: size in words
     bits 16-31: name string ref
     bits 32-63: int32 value
*)
let[@inline] put_arg_header_i32 buf pos arg_words name_ref value =
  put_raw_64_le buf pos
    Int64.(
      logor 1L (* arg type = int32 *)
        (logor
           (shift_left (of_int arg_words) 4)
           (logor
              (shift_left (of_int name_ref) 16)
              (shift_left (of_int value) 32))))

(* Pack an FXT argument header for an int64 argument and write it.

   Layout (64 bits):
     bits  0-3:  argument type (3 = int64)
     bits  4-15: size in words
     bits 16-31: name string ref
*)
let[@inline] put_arg_header_i64 buf pos arg_words name_ref =
  put_raw_64_le buf pos
    Int64.(
      logor 3L (* arg type = int64 *)
        (logor
           (shift_left (of_int arg_words) 4)
           (shift_left (of_int name_ref) 16)))
