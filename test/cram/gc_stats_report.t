Test for isolation of domain gc stats in presence of reused ring ids.

Spawn and join many domains in sequence:
  $ cat > seq.ml <<'EOF'
  > let () =
  >   for _ = 1 to 50 do
  >     Domain.join (Domain.spawn (fun () ->
  >       let r = ref [] in
  >       for i = 1 to 100_000 do r := [ i ] (* Lots of short lived allocs *) done;
  >       ignore (Sys.opaque_identity !r)) (* Force no optimization *))
  >   done;
  >   print_endline "50 domains have been spawned and joined in sequence"
  > EOF
  $ ocamlopt seq.ml -o ./seq.exe

Collect GC stats:
  $ olly gc-stats -o stats.json --json ./seq.exe
  50 domains have been spawned and joined in sequence

Check GC time / domain elapsed time computation:
  $ olly validate-gc-stats stats.json | grep -e "0 <= gc_time <= wall_time" -e "gc_overhead" || echo OK
  OK

Check outlier computation:
  $ olly validate-gc-stats stats.json | grep -e "mean_latency" -e "max_latency" || echo OK
  OK
