open Olly_format_backend
open Tracing

let name = "fuchsia"
let description = "Perfetto"

type trace = { doms : Trace.Thread.t array; file : Trace.t }

let create ~filename =
  let file = Trace.create_for_file ~base_time:None ~filename in
  let doms =
    let max_doms = 128 in
    Array.init max_doms (fun i ->
        (* Use a different pid for each domain *)
        Trace.allocate_thread file ~pid:i ~name:(Printf.sprintf "Ring_id %d" i))
  in
  { doms; file }

let close trace = Trace.close trace.file
let ts_to_span ts = ts |> Int64.to_int |> Core.Time_ns.Span.of_int_ns

let emit trace evt =
  let open Event in
  let thread = trace.doms.(evt.ring_id)
  and category = "PERF"
  and time = ts_to_span evt.ts
  and name = evt.name in
  match evt.kind with
  | SpanBegin | SpanEnd ->
      let write =
        if evt.kind = SpanBegin then Trace.write_duration_begin
        else Trace.write_duration_end
      in
      write trace.file ~args:[] ~thread ~category ~name ~time
  | Counter value ->
      Trace.write_counter trace.file ~thread ~category ~name ~time
        ~args:[ ("v", Int value) ]
  | Instant ->
      Trace.write_duration_instant trace.file ~args:[] ~thread ~category ~name
        ~time
  | _ -> ()
