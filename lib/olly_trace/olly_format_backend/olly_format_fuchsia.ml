open Olly_format_backend

let name = "fuchsia"
let description = "Perfetto"

module Trace = Trace_fuchsia.Writer

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
    (* Upper limit for OCaml domain count (OCAMLRUNPARAM=d<N> ceiling) *)
    let max_doms = 4096 in
    Array.init max_doms (fun i ->
        (* Use a different pid for each domain *)
        Trace.Thread_ref.ref (i + 1))
  in
  { doms; buf; collector; exporter }

let close trace =
  flush trace;
  Trace_fuchsia.Collector_fuchsia.close trace.collector

let emit_counter trace ~ring_id ~ts ~name ~value =
  let t_ref = trace.doms.(ring_id) and time_ns = ts in
  Trace.Event.Counter.encode trace.buf ~t_ref ~name ~time_ns
    ~args:[ ("v", A_int value) ]
    ()

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
  | Counter value ->
      Trace.Event.Counter.encode trace.buf ~t_ref ~name ~time_ns
        ~args:[ ("v", A_int value) ]
        ()
  | Instant ->
      Trace.Event.Instant.encode trace.buf ~name ~args:[] ~t_ref ~time_ns ()
  | _ -> ()
