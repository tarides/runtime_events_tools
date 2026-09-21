(* from https://github.com/tarides/runtime_events_tools/issues/113 *)

let work () =
  let acc = ref [] in
  for i = 1 to 400_000 do
    acc := Array.make 8 i :: !acc;
    if i mod 1000 = 0 then acc := []
  done;
  ignore (Sys.opaque_identity !acc)

let () =
  let ds = Array.init 3 (fun _ -> Domain.spawn work) in
  Array.iter Domain.join ds
