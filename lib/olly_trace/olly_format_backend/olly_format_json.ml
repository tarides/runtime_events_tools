open Olly_format_backend

let name = "json"
let description = "Chrome Trace Format"

type trace = { file : out_channel; buf : Buffer.t; digits : Bytes.t }

let create ~filename =
  let file = open_out filename in
  output_string file "[";
  { file; buf = Buffer.create 256; digits = Bytes.create 20 }

let close trace = close_out trace.file

let buf_add_int buf digits n =
  if n = 0 then Buffer.add_char buf '0'
  else begin
    let n =
      if n < 0 then (
        Buffer.add_char buf '-';
        -n)
      else n
    in
    let pos = ref (Bytes.length digits) in
    let n = ref n in
    while !n > 0 do
      decr pos;
      Bytes.set digits !pos (Char.chr (Char.code '0' + (!n mod 10)));
      n := !n / 10
    done;
    Buffer.add_subbytes buf digits !pos (Bytes.length digits - !pos)
  end

(* Write timestamp as microseconds (ts_ns / 1000) directly into the buffer
   using a C stub. Avoids ~30 boxed Int64 allocations from digit-by-digit
   Int64.div/Int64.rem in OCaml. *)
let buf_add_ts_us buf digits ts =
  let len = Fxt_buf.int64_div_to_decimal digits 0 ts 1000 in
  Buffer.add_subbytes buf digits 0 len

let write_span trace ~name ~ts ~ring_id ph =
  let buf = trace.buf and digits = trace.digits in
  Buffer.clear buf;
  Buffer.add_string buf "{\"name\": \"";
  Buffer.add_string buf name;
  Buffer.add_string buf "\", \"cat\": \"PERF\", \"ph\":\"";
  Buffer.add_string buf ph;
  Buffer.add_string buf "\", \"ts\":";
  buf_add_ts_us buf digits ts;
  Buffer.add_string buf ", \"pid\": ";
  buf_add_int buf digits ring_id;
  Buffer.add_string buf ", \"tid\": ";
  buf_add_int buf digits ring_id;
  Buffer.add_string buf "},\n";
  Buffer.output_buffer trace.file buf

let write_counter trace ~name ~ts ~ring_id value =
  let buf = trace.buf and digits = trace.digits in
  Buffer.clear buf;
  Buffer.add_string buf "{\"name\": \"";
  Buffer.add_string buf name;
  Buffer.add_string buf "\", \"cat\": \"PERF\", \"ph\":\"C\", \"ts\":";
  buf_add_ts_us buf digits ts;
  Buffer.add_string buf ", \"pid\": ";
  buf_add_int buf digits ring_id;
  Buffer.add_string buf ", \"tid\": ";
  buf_add_int buf digits ring_id;
  Buffer.add_string buf ", \"args\": {\"";
  Buffer.add_string buf name;
  Buffer.add_string buf "\": ";
  buf_add_int buf digits value;
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
