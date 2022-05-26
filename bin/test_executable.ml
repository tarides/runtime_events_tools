let () =
  let started = Sys.time() in
  while (Sys.time() -. started < 4.0) do
    let l = ref [] in
    for _ = 0 to 3 do
      for i = 0 to 1_000_000 do
        l := i :: !l
      done;
      Gc.full_major ();
    done;
  done