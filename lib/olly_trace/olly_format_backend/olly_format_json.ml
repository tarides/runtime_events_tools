open Olly_format_backend

let name = "json"
let description = "Chrome Trace Format"

type trace =
  { file : out_channel }
let create ~filename =
  let file = open_out filename in
  Printf.fprintf file "[";
  { file }

let close trace =
  close_out trace.file

let ts_to_us ts = Int64.(div ts (of_int 1000))

let write_json trace evt ph args =
  let open Event in
  Printf.fprintf trace.file
    "{\"name\": \"%s\", \"cat\": \"PERF\", \"ph\":\"%s\", \"ts\":%Ld, \
     \"pid\": %d, \"tid\": %d%t},\n"
    evt.name ph (ts_to_us evt.ts) evt.ring_id evt.ring_id
    (match args with
     | None -> ignore
     | Some args -> fun oc -> Printf.fprintf oc ", \"args\": %t" args)
let emit trace evt =
  let open Event in
  match evt.kind with
  | SpanBegin | SpanEnd ->
     write_json trace evt
       (if evt.kind = SpanBegin then "B" else "E")
       None
  | Counter value ->
     Some(fun oc -> Printf.fprintf oc "{\"%s\": %d}" evt.name value) |>
       write_json trace evt "C"
  | Instant -> write_json trace evt "i" None
  | _ -> ()
