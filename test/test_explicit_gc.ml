(* Regression test: explicit GC calls made from a domain other than the main
   one must still be counted. The EV_EXPLICIT_GC_* phases are emitted only on
   the domain that made the call, so counting them on domain index 0 alone
   silently reports zero here. *)

let rounds = 5

let work () =
  for _ = 1 to rounds do
    let acc = ref [] in
    for i = 1 to 20000 do
      acc := Array.make 8 i :: !acc
    done;
    ignore (Sys.opaque_identity !acc);
    Gc.full_major ();
    Gc.compact ()
  done

let () = Domain.join (Domain.spawn work)
