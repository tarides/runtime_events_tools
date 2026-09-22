(* Allocation-heavy but small-footprint: a live set of a few kB, and enough
   minor collections to write tens of MB of runtime events. Used to check that
   the ring buffer's resident pages are kept out of the reported max RSS. *)
let () =
  for _ = 1 to 150_000 do
    for _ = 1 to 400 do
      ignore (Sys.opaque_identity (Array.make 4 0))
    done;
    Gc.minor ()
  done
