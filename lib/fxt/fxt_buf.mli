(** Low-level buffer for writing FXT (Fuchsia trace format) binary data.

    Provides a fixed-size {!Bytes.t}-backed buffer with zero-allocation
    write primitives. Integer writes use compiler intrinsics and C stubs
    to avoid {!Int64} boxing. Strings are written with 8-byte alignment
    padding as required by the FXT specification.

    @see <https://fuchsia.dev/fuchsia-src/reference/tracing/trace-format> *)

(** A write buffer backed by a fixed-size {!Bytes.t}. *)
type t

val create : int -> t
(** [create n] allocates a buffer of [n] bytes (rounded up to 8-byte
    alignment). *)

val clear : t -> unit
(** [clear t] resets the write position to the beginning. *)

val pos : t -> int
(** [pos t] returns the current write position in bytes. *)

val available : t -> int
(** [available t] returns the number of bytes remaining. *)

val bytes : t -> Bytes.t
(** [bytes t] returns the underlying {!Bytes.t}. Used with C stubs that
    write directly at a given offset. *)

val put_64 : t -> int64 -> unit
(** [put_64 t v] writes [v] as a little-endian 64-bit integer and advances
    the position by 8 bytes. *)

val put_string_padded : t -> string -> unit
(** [put_string_padded t s] writes [s] followed by zero-padding to the next
    8-byte boundary, as required by FXT string encoding. *)

val advance : t -> int -> unit
(** [advance t n] moves the write position forward by [n] bytes. Used after
    C stubs that write directly into {!bytes}. *)

val flush : t -> out_channel -> unit
(** [flush t oc] writes all buffered data to [oc] and resets the position. *)

(** {1 Zero-allocation C stubs}

    These externals write packed binary headers directly into a {!Bytes.t}
    at a given offset, avoiding intermediate {!Int64} boxing that would
    occur with OCaml's [Int64.logor]/[Int64.shift_left] operations. *)

external put_raw_64_le : Bytes.t -> int -> int64 -> unit = "%caml_bytes_set64u"
[@@noalloc]
(** Compiler intrinsic: writes a 64-bit integer in little-endian byte order
    at an unaligned offset. Compiles to a single store instruction on x86-64. *)

external put_event_header :
  Bytes.t -> int -> int -> int -> int -> int -> int -> unit
  = "fxt_put_event_header_bytecode" "fxt_put_event_header_native"
[@@noalloc]
(** [put_event_header buf pos size event_ty n_args thread_ref name_ref]
    packs and writes a 64-bit FXT event record header. Fields are:
    - [size]: total record size in 8-byte words
    - [event_ty]: event type (0=instant, 1=counter, 2=duration_begin, 3=duration_end)
    - [n_args]: number of arguments (0-15)
    - [thread_ref]: thread reference index (0 for inline)
    - [name_ref]: string reference for the event name *)

external put_arg_header_i32 : Bytes.t -> int -> int -> int -> int -> unit
  = "fxt_put_arg_header_i32"
[@@noalloc]
(** [put_arg_header_i32 buf pos arg_words name_ref value] packs and writes
    a 64-bit FXT argument header for a 32-bit integer argument. The [value]
    is stored inline in the upper 32 bits of the header word. *)

external put_arg_header_i64 : Bytes.t -> int -> int -> int -> unit
  = "fxt_put_arg_header_i64"
[@@noalloc]
(** [put_arg_header_i64 buf pos arg_words name_ref] packs and writes a
    64-bit FXT argument header for a 64-bit integer argument. The value
    must be written separately as a following word. *)

external int64_div_to_decimal : Bytes.t -> int -> int64 -> int -> int
  = "fxt_int64_div_to_decimal"
[@@noalloc]
(** [int64_div_to_decimal buf pos n divisor] divides [n] by [divisor] and
    writes the result as decimal ASCII digits into [buf] at [pos]. Returns
    the number of bytes written. Used for JSON timestamp formatting
    (nanoseconds to microseconds) without {!Int64} boxing. *)
