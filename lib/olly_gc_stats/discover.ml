module C = Configurator.V1

let code counter_name =
  Printf.sprintf
    {|
  #include "caml/runtime_events.h"
  int main(void) { return %s;}
  |}
    counter_name


let counters_to_suffix =
[ ["EV_C_MINOR_PROMOTED_WORDS"; "EV_C_MINOR_ALLOCATED_WORDS"; "EV_C_MAJOR_ALLOCATED_WORDS"], "5.5"
; ["EV_C_MINOR_PROMOTED"; "EV_C_MINOR_ALLOCATED"; "EV_C_MAJOR_ALLOCATED_WORDS"], "5.3"
]

let () =
  C.main ~name:"Runtime_events constants" @@ fun c ->
  let has_counter name = C.c_test c (code name) in
  let check (counters, suffix) =
    if List.for_all has_counter counters then Some suffix
    else None
  in
  let shim = List.find_map check counters_to_suffix |> Option.value ~default:"5.0" in
  C.Flags.write_lines "gc_counters_shim.suffix" [shim];
  C.Flags.write_lines "olly_gc_stats.suffix" [min "5.3" shim]
