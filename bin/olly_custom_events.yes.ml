open Tracing
module Ts = Runtime_events.Timestamp

let ts_to_int ts = ts |> Ts.to_int64 |> Int64.to_int
let int_to_span i = Core.Time_ns.Span.of_int_ns i

let span trace_file doms ring_id ts ev value =
  let thread = doms.(ring_id) in
  let name = Runtime_events.User.name ev in
  let fn =
    if value = Runtime_events.Type.Begin then Trace.write_duration_begin
    else Trace.write_duration_end
  in
  fn trace_file ~args:[] ~thread ~category:"PERF" ~name
    ~time:(ts |> ts_to_int |> int_to_span)

let int trace_file doms ring_id ts ev value =
  let thread = doms.(ring_id) in
  let name = Runtime_events.User.name ev in
  Trace.write_counter trace_file
    ~args:[ ("v", Int value) ]
    ~thread ~category:"PERF" ~name
    ~time:(ts |> ts_to_int |> int_to_span)

let unit trace_file doms ring_id ts ev () =
  let thread = doms.(ring_id) in
  let name = Runtime_events.User.name ev in
  Trace.write_duration_instant trace_file ~args:[] ~thread ~category:"PERF"
    ~name
    ~time:(ts |> ts_to_int |> int_to_span)

let span_json trace_file ring_id ts ev value =
  let ts_to_us ts = Int64.(div (Ts.to_int64 ts) (of_int 1000)) in
  let name = Runtime_events.User.name ev in
  if value = Runtime_events.Type.Begin then
    Printf.fprintf trace_file
      "{\"name\": \"%s\", \"cat\": \"PERF\", \"ph\":\"B\", \"ts\":%Ld, \
       \"pid\": %d, \"tid\": %d},\n"
      name (ts_to_us ts) ring_id ring_id
  else
    Printf.fprintf trace_file
      "{\"name\": \"%s\", \"cat\": \"PERF\", \"ph\":\"E\", \"ts\":%Ld, \
       \"pid\": %d, \"tid\": %d},\n"
      name (ts_to_us ts) ring_id ring_id

let v trace_file doms cb =
  let open Runtime_events in
  cb
  |> Callbacks.add_user_event Type.span (span trace_file doms)
  |> Callbacks.add_user_event Type.int (int trace_file doms)
  |> Callbacks.add_user_event Type.unit (unit trace_file doms)

let v_json trace_file cb =
  let open Runtime_events in
  cb |> Callbacks.add_user_event Type.span (span_json trace_file)
