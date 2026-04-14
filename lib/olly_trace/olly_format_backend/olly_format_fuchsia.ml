open Olly_format_backend

let name = "fuchsia"
let description = "Perfetto"

module Trace = Trace_fuchsia.Writer
module I64 = Trace.I64
module Buf = Trace_fuchsia.Buf

(* Equivalent to the private str_len_word in Writer *)
let[@inline] str_len_word (s : string) =
  let len = String.length s in
  (* round_to_word len / 8 *)
  (len + (lnot (len - 1) land 7)) asr 3

let[@inline] is_i32 (i : int) : bool = Int32.(to_int (of_int i) = i)

type trace = {
  doms : Trace.Thread_ref.t array;
  buf : Trace_fuchsia.Buf_chain.t;
  collector : Trace_fuchsia.Collector_fuchsia.t;
  exporter : Trace_fuchsia.Exporter.t;
}

let flush trace =
  Trace_fuchsia.Buf_chain.ready_all_non_empty trace.buf;
  Trace_fuchsia.Buf_chain.pop_ready trace.buf ~f:trace.exporter.write_bufs;
  trace.exporter.flush ()

let create ~filename =
  let buf_pool = Trace_fuchsia.Buf_pool.create () in
  let buf = Trace_fuchsia.Buf_chain.create ~sharded:true ~buf_pool () in
  let oc = Out_channel.open_bin filename in
  let exporter = Trace_fuchsia.Exporter.of_out_channel ~close_channel:true oc in
  let collector =
    Trace_fuchsia.Collector_fuchsia.create ~buf_pool ~pid:0 ~exporter ()
  in
  (* Adds the headers to output *)
  Trace_fuchsia.Collector_fuchsia.callbacks.init collector;
  let doms =
    (* Upper limit for OCaml domain count (OCAMLRUNPARAM=d<N> ceiling).
       Thread_ref.inline is used instead of Thread_ref.ref because inline
       refs support arbitrary pid/tid values whereas ref is limited to
       1-255. *)
    let max_doms = 4096 in
    Array.init max_doms (fun i ->
        Trace.Thread_ref.inline ~pid:(i + 1) ~tid:0)
  in
  { doms; buf; collector; exporter }

let close trace =
  flush trace;
  Trace_fuchsia.Collector_fuchsia.close trace.collector

(* Zero-allocation counter event encoding. Writes directly into the fuchsia
   trace buffer, bypassing Trace.Event.Counter.encode which requires an
   allocated args list. Encodes a single A_int argument named "v". *)
let write_counter_event bufs ~t_ref ~time_ns ~name ~value =
  let name_words = str_len_word name in
  (* arg: header(1) + name "v" (1 word) + maybe payload *)
  let arg_words = if is_i32 value then 2 else 3 in
  let size =
    1 (* event header *) + Trace.Thread_ref.size_word t_ref + 1 (* timestamp *)
    + name_words + arg_words + 1 (* counter id *)
  in
  let (@ ) = I64.( lor ) in
  Trace_fuchsia.Buf_chain.with_buf bufs ~available_word:size (fun buf ->
      (* Event header: type=4 (counter), size, n_args=1, t_ref, name str_ref *)
      let hd =
        I64.of_int 4
        @ I64.shift_left (I64.of_int size) 4
        @ I64.shift_left 1L 16 (* n_args = 1 *)
        @ I64.shift_left (I64.of_int (Trace.Thread_ref.as_i8 t_ref)) 24
        @ I64.shift_left
            (I64.of_int (Trace.Str_ref.inline (String.length name)))
            48
      in
      Buf.add_i64 buf hd;
      Buf.add_i64 buf time_ns;
      (* Inline thread ref: pid + tid *)
      (match t_ref with
      | Trace.Thread_ref.Inline { pid; tid } ->
          Buf.add_i64 buf (I64.of_int pid);
          Buf.add_i64 buf (I64.of_int tid)
      | Trace.Thread_ref.Ref _ -> ());
      Buf.add_string buf name;
      (* Argument "v" with int value.
         Fuchsia arg layout: header word, name string, then payload (i64 only).
         For i32: value is packed into header bits [32:63], no separate payload.
         For i64: payload word follows the name string. *)
      let v_str_ref = Trace.Str_ref.inline 1 in
      let arg_hd_base =
        I64.shift_left (I64.of_int (if is_i32 value then 2 else 3)) 4
        @ I64.shift_left (I64.of_int v_str_ref) 16
      in
      if is_i32 value then begin
        let arg_hd =
          1L (* type = int32 *)
          @ arg_hd_base
          @ I64.shift_left (I64.of_int value) 32
        in
        Buf.add_i64 buf arg_hd;
        Buf.add_string buf "v"
      end
      else begin
        let arg_hd = 3L (* type = int64 *) @ arg_hd_base in
        Buf.add_i64 buf arg_hd;
        Buf.add_string buf "v";
        Buf.add_i64 buf (I64.of_int value)
      end;
      (* Counter ID *)
      Buf.add_i64 buf 0L)

let emit_counter trace ~ring_id ~ts ~name ~value =
  let t_ref = trace.doms.(ring_id) in
  write_counter_event trace.buf ~t_ref ~time_ns:ts ~name ~value

let emit trace ~ring_id ~ts ~name ~kind =
  let open Event in
  let t_ref = trace.doms.(ring_id) and time_ns = ts in
  match kind with
  | SpanBegin ->
      Trace.Event.Duration_begin.encode trace.buf ~args:[] ~t_ref ~name
        ~time_ns ()
  | SpanEnd ->
      Trace.Event.Duration_end.encode trace.buf ~args:[] ~t_ref ~name
        ~time_ns ()
  | Counter value -> write_counter_event trace.buf ~t_ref ~time_ns ~name ~value
  | Instant ->
      Trace.Event.Instant.encode trace.buf ~name ~args:[] ~t_ref ~time_ns ()
  | _ -> ()
