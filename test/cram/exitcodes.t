Olly exits with code 0 when the launched OCaml program succeeds:
  $ olly latency -o t1.out ../run_exit.exe

Olly exits with non-zero code when the launched OCaml program fails:
  $ olly latency -o t2.out ../run_exit.exe 42
  olly: Child exited with code 42
  [124]
