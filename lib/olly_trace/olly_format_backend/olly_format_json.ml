open Olly_format_backend

let name = "json"
let description = "Chrome Trace Format"

type trace = { file : out_channel; mutable first : bool }

let create ~filename =
  let file = open_out filename in
  output_char file '[';
  { file; first = true }

let[@inline] array_elt_begin trace =
  if trace.first then trace.first <- false else Printf.fprintf trace.file ","

let close trace =
  output_char trace.file ']';
  close_out trace.file

let ts_to_us ts = Int64.(to_float ts /. 1000.)

let write_json trace ~name ~ts ~ring_id ph args =
  array_elt_begin trace;
  Printf.fprintf trace.file
    "{\"name\": \"%s\", \"cat\": \"PERF\", \"ph\":\"%s\", \"ts\":%.3f, \
     \"pid\": %d, \"tid\": %d%t}\n"
    name ph (ts_to_us ts) ring_id ring_id
    (match args with
    | None -> ignore
    | Some args -> fun oc -> Printf.fprintf oc ", \"args\": %t" args)

let emit_counter trace ~ring_id ~ts ~name ~value =
  Some (fun oc -> Printf.fprintf oc "{\"%s\": %d}" name value)
  |> write_json trace ~name ~ts ~ring_id "C"

let emit trace ~ring_id ~ts ~name ~kind =
  let open Event in
  match kind with
  | SpanBegin -> write_json trace ~name ~ts ~ring_id "B" None
  | SpanEnd -> write_json trace ~name ~ts ~ring_id "E" None
  | Counter value -> emit_counter trace ~ring_id ~ts ~name ~value
  | Instant -> write_json trace ~name ~ts ~ring_id "i" None
  | _ -> ()
