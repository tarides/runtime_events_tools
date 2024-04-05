open Event
open Runtime_events

type _ custom_type = ..

type _ custom_type +=
  | Span : Type.span custom_type
  | Int : int custom_type
  | Unit : unit custom_type

type tag += Custom : 'a User.t * 'a custom_type -> tag

let from_int x = Counter x
let from_unit () = Instant

let from_span (s : Type.span) =
  match s with Begin -> SpanBegin | End -> SpanEnd

let add_to cb sc =
  let emit cty get_kind ring_id ts evt value =
    sc
      {
        ring_id;
        ts = ts_to_int64 ts;
        name = User.name evt;
        tag = Custom (evt, cty);
        kind = get_kind value;
      }
  in
  cb
  |> Callbacks.add_user_event Type.span (emit Span from_span)
  |> Callbacks.add_user_event Type.int (emit Int from_int)
  |> Callbacks.add_user_event Type.unit (emit Unit from_unit)
