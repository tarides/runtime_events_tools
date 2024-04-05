open Event
open Runtime_events

let builtin_names (k : shim_callback) (evt : event) : unit =
  k
  @@
  match evt.tag with
  | Runtime_phase ph -> { evt with name = runtime_phase_name ph }
  | Runtime_counter cnt -> { evt with name = runtime_counter_name cnt }
  | Lifecycle lc -> { evt with name = lifecycle_name lc }
  | _ -> evt

let builtin_name_table = Builtin_name_table.name_table
let tabled_names = Tabling.tabled_names

let make_callbacks (sc : shim_callback) : Callbacks.t =
  let runtime_begin ring_id ts ph =
    sc
      {
        ring_id;
        ts = ts_to_int64 ts;
        name = "?";
        tag = Runtime_phase ph;
        kind = SpanBegin;
      }
  and runtime_end ring_id ts ph =
    sc
      {
        ring_id;
        ts = ts_to_int64 ts;
        name = "?";
        tag = Runtime_phase ph;
        kind = SpanEnd;
      }
  and runtime_counter ring_id ts cntr cnt =
    sc
      {
        ring_id;
        ts = ts_to_int64 ts;
        name = "?";
        tag = Runtime_counter cntr;
        kind = Counter cnt;
      }
  and alloc ring_id ts allocs =
    sc
      {
        ring_id;
        ts = ts_to_int64 ts;
        name = "alloc";
        tag = Alloc;
        kind = IntArray allocs;
      }
  and lifecycle ring_id ts lc arg =
    sc
      {
        ring_id;
        ts = ts_to_int64 ts;
        name = "?";
        tag = Lifecycle lc;
        kind = MaybeInt arg;
      }
  and lost_events ring_id cnt =
    sc
      {
        ring_id;
        ts = 0L;
        name = "lost_events";
        tag = Lost_events;
        kind = Counter cnt;
      }
  in
  let cb =
    Callbacks.create ~runtime_begin ~runtime_end ~runtime_counter ~alloc
      ~lifecycle ~lost_events ()
  in
  Custom_events.add_to cb sc
