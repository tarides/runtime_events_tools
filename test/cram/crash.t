Olly exits with non-zero code when the launched OCaml program crashes.

Windows has no signals: [Unix.kill] with [SIGKILL] does terminate the child,
but the parent's [waitpid] reports [WEXITED 0], indistinguishable from a
clean exit, so there is nothing for olly to report.

grep the Warning lines out as they contain timing info which is not reproducible.

  $ olly gc-stats -o t3.out ../run_crash.exe 2>&1 | grep -v Warning
  olly: Child killed by signal SIGKILL
