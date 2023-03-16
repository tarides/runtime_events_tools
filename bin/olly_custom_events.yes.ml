
open Tracing
module Ts = Runtime_events.Timestamp

let ts_to_int ts = ts |> Ts.to_int64 |> Int64.to_int
let int_to_span i = Core.Time_ns.Span.of_int_ns i

let span trace_file doms ring_id ts ev value =
  let thread = doms.(ring_id) in
  let name = Runtime_events.User.name ev in
  let fn =
    if value = Runtime_events.Type.Begin then
      Trace.write_duration_begin
    else Trace.write_duration_end
  in
  fn trace_file ~args:[] ~thread ~category:"PERF"
    ~name
    ~time:(ts |> ts_to_int |> int_to_span)

let int trace_file doms ring_id ts ev value =
  let thread = doms.(ring_id) in
  let name = Runtime_events.User.name ev in
  Trace.write_counter trace_file ~args:[("v", Int value)] ~thread
    ~category:"PERF"
    ~name
    ~time:(ts |> ts_to_int |> int_to_span)

let unit trace_file doms ring_id ts ev () =
  let thread = doms.(ring_id) in
  let name = Runtime_events.User.name ev in
  Trace.write_duration_instant trace_file ~args:[] ~thread
    ~category:"PERF"
    ~name
    ~time:(ts |> ts_to_int |> int_to_span)


let v trace_file doms cb =
  let open Runtime_events in
  cb
  |> Callbacks.add_user_event Type.span (span trace_file doms)
  |> Callbacks.add_user_event Type.int (int trace_file doms)
  |> Callbacks.add_user_event Type.unit (unit trace_file doms)
