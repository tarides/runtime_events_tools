open Olly_format_backend

let name = "fuchsia"
let description = "Perfetto"

module Trace = Trace_fuchsia.Writer

type trace = {
  doms : Trace.Thread_ref.t array;
  buf : Trace_fuchsia.Buf_chain.t;
  subscriber : Trace_fuchsia.Subscriber.t;
  exporter : Trace_fuchsia.Exporter.t;
}

let flush trace =
  Trace_fuchsia.Buf_chain.ready_all_non_empty trace.buf;
  Trace_fuchsia.Buf_chain.pop_ready trace.buf ~f:trace.exporter.write_bufs;
  trace.exporter.flush ()

let create ~filename =
  let buf_pool = Trace_fuchsia.Buf_pool.create () in
  let buf = Trace_fuchsia.Buf_chain.create ~sharded:false ~buf_pool () in
  let oc = Out_channel.open_bin filename in
  let exporter = Trace_fuchsia.Exporter.of_out_channel ~close_channel:true oc in
  let subscriber =
    Trace_fuchsia.Subscriber.create ~buf_pool ~pid:0 ~exporter ()
  in
  (* Adds the headers to output *)
  Trace_fuchsia.Subscriber.Callbacks.on_init subscriber ~time_ns:0L;
  let doms =
    let max_doms = 128 in
    Array.init max_doms (fun i ->
        (* Use a different pid for each domain *)
        Trace.Thread_ref.ref (i + 1))
  in
  { doms; buf; subscriber; exporter }

let close trace =
  flush trace;
  Trace_fuchsia.Subscriber.close trace.subscriber

let emit trace evt =
  let open Event in
  let t_ref = trace.doms.(evt.ring_id)
  and time_ns = evt.ts
  and name = evt.name in
  match evt.kind with
  | SpanBegin | SpanEnd ->
      let write =
        if evt.kind = SpanBegin then Trace.Event.Duration_begin.encode
        else Trace.Event.Duration_end.encode
      in
      write trace.buf ~args:[] ~t_ref ~name ~time_ns ()
  | Counter value ->
      Trace.Event.Counter.encode trace.buf ~t_ref ~name ~time_ns
        ~args:[ ("v", A_int value) ]
        ()
  | Instant ->
      Trace.Event.Instant.encode trace.buf ~name ~args:[] ~t_ref ~time_ns ()
  | _ -> ()
