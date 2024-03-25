module Trace = Olly_format_backend
open Trace.Event
open Runtime_events

let emit tracer get_kind ring_id ts ev value =
  Trace.emit tracer
    { name = User.name ev
    ; ts = Timestamp.to_int64 ts
    ; ring_id
    ; kind = get_kind value }

let from_int x = Counter x
let from_unit () = Instant
let from_span (s : Type.span) =
  match s with
  | Begin -> SpanBegin
  | End -> SpanEnd

let v tracer cb =
  let open Runtime_events in
  cb
  |> Callbacks.add_user_event Type.span (emit tracer from_span)
  |> Callbacks.add_user_event Type.int (emit tracer from_int)
  |> Callbacks.add_user_event Type.unit (emit tracer from_unit)
