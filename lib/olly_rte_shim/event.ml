type kind = ..

type kind +=
  | SpanBegin
  | SpanEnd
  | Instant
  | Counter of int
  | IntArray of int array
  | MaybeInt of int option

type tag = ..

type tag +=
  | Lifecycle of Runtime_events.lifecycle
  | Runtime_phase of Runtime_events.runtime_phase
  | Runtime_counter of Runtime_events.runtime_counter
  | Alloc
  | Lost_events

type event = {
  ring_id : int;
  ts : int64;
  name : string;
  tag : tag;
  kind : kind;
}

type shim_callback = event -> unit
(** A simple, unified event handler callback *)

let ts_to_int64 = Runtime_events.Timestamp.to_int64
