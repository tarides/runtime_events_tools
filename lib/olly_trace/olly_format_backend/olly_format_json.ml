open Olly_format_backend

let name = "json"
let description = "Chrome Trace Format"

type trace = { file : out_channel }

let create ~filename =
  let file = open_out filename in
  Printf.fprintf file "[";
  { file }

let close trace = close_out trace.file
let ts_to_us ts = Int64.(div ts (of_int 1000))

let write_json trace ~name ~ts ~ring_id ph args =
  Printf.fprintf trace.file
    "{\"name\": \"%s\", \"cat\": \"PERF\", \"ph\":\"%s\", \"ts\":%Ld, \"pid\": \
     %d, \"tid\": %d%t},\n"
    name ph (ts_to_us ts) ring_id ring_id
    (match args with
    | None -> ignore
    | Some args -> fun oc -> Printf.fprintf oc ", \"args\": %t" args)

let emit trace ~ring_id ~ts ~name ~kind =
  let open Event in
  match kind with
  | SpanBegin -> write_json trace ~name ~ts ~ring_id "B" None
  | SpanEnd -> write_json trace ~name ~ts ~ring_id "E" None
  | Counter value ->
      Some (fun oc -> Printf.fprintf oc "{\"%s\": %d}" name value)
      |> write_json trace ~name ~ts ~ring_id "C"
  | Instant -> write_json trace ~name ~ts ~ring_id "i" None
  | _ -> ()
