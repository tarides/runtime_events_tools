open Olly_format_backend

let name = "fuchsia"
let description = "Perfetto"

type trace = {
  writer : Fxt_write.t;
  doms : Fxt_write.thread array;
}

let create ~filename =
  let oc = Out_channel.open_bin filename in
  let writer = Fxt_write.create oc in
  let max_doms = 4096 in
  let doms =
    Array.init max_doms (fun i ->
        Fxt_write.{ pid = Int64.of_int (i + 1); tid = 0L })
  in
  { writer; doms }

let close trace = Fxt_write.close trace.writer

let emit_counter trace ~ring_id ~ts ~name ~value =
  let thread = trace.doms.(ring_id) in
  Fxt_write.counter trace.writer ~thread ~name ~ts ~value

let emit trace ~ring_id ~ts ~name ~kind =
  let open Event in
  let thread = trace.doms.(ring_id) in
  match kind with
  | SpanBegin -> Fxt_write.duration_begin trace.writer ~thread ~name ~ts
  | SpanEnd -> Fxt_write.duration_end trace.writer ~thread ~name ~ts
  | Counter value -> Fxt_write.counter trace.writer ~thread ~name ~ts ~value
  | Instant -> Fxt_write.instant trace.writer ~thread ~name ~ts
  | _ -> ()
