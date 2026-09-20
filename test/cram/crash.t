Olly exits with non-zero code when the launched OCaml program crashes.

Windows has no signals: [Unix.kill] with [SIGKILL] does terminate the child,
but the parent's [waitpid] reports [WEXITED 0], indistinguishable from a
clean exit, so there is nothing for olly to report.

  $ olly latency -o t3.out ../run_crash.exe
  olly: Child killed by signal SIGKILL
  [124]
