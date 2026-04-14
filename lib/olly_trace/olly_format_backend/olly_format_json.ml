open Olly_format_backend

let name = "json"
let description = "Chrome Trace Format"

type trace = { file : out_channel; buf : Buffer.t }

let create ~filename =
  let file = open_out filename in
  output_string file "[";
  { file; buf = Buffer.create 256 }

let close trace = close_out trace.file

let write_span trace ~name ~ts ~ring_id ph =
  let buf = trace.buf in
  Buffer.clear buf;
  Buffer.add_string buf "{\"name\": \"";
  Buffer.add_string buf name;
  Buffer.add_string buf "\", \"cat\": \"PERF\", \"ph\":\"";
  Buffer.add_string buf ph;
  Buffer.add_string buf "\", \"ts\":";
  Buffer.add_string buf (Int64.to_string (Int64.div ts 1000L));
  Buffer.add_string buf ", \"pid\": ";
  Buffer.add_string buf (string_of_int ring_id);
  Buffer.add_string buf ", \"tid\": ";
  Buffer.add_string buf (string_of_int ring_id);
  Buffer.add_string buf "},\n";
  Buffer.output_buffer trace.file buf

let write_counter trace ~name ~ts ~ring_id value =
  let buf = trace.buf in
  Buffer.clear buf;
  Buffer.add_string buf "{\"name\": \"";
  Buffer.add_string buf name;
  Buffer.add_string buf "\", \"cat\": \"PERF\", \"ph\":\"C\", \"ts\":";
  Buffer.add_string buf (Int64.to_string (Int64.div ts 1000L));
  Buffer.add_string buf ", \"pid\": ";
  Buffer.add_string buf (string_of_int ring_id);
  Buffer.add_string buf ", \"tid\": ";
  Buffer.add_string buf (string_of_int ring_id);
  Buffer.add_string buf ", \"args\": {\"";
  Buffer.add_string buf name;
  Buffer.add_string buf "\": ";
  Buffer.add_string buf (string_of_int value);
  Buffer.add_string buf "}},\n";
  Buffer.output_buffer trace.file buf

let emit_counter trace ~ring_id ~ts ~name ~value =
  write_counter trace ~name ~ts ~ring_id value

let emit trace ~ring_id ~ts ~name ~kind =
  let open Event in
  match kind with
  | SpanBegin -> write_span trace ~name ~ts ~ring_id "B"
  | SpanEnd -> write_span trace ~name ~ts ~ring_id "E"
  | Counter value -> write_counter trace ~name ~ts ~ring_id value
  | Instant -> write_span trace ~name ~ts ~ring_id "i"
  | _ -> ()
