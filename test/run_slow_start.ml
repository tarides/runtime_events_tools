(* Emulates a child that reaches its runtime events initialisation late.

   Launched without OCAML_RUNTIME_EVENTS_START, nothing creates a ring buffer
   while the runtime starts up: the [<pid>.events] file appears in
   OCAML_RUNTIME_EVENTS_DIR only when this program calls
   [Runtime_events.start], [delay] seconds in. Unlike a shell that sleeps and
   then execs the traced program, this keeps the pid, and hence the name of
   the ring file, unchanged on every platform, including Windows, which has no
   [exec]. *)
let () =
  let delay = float_of_string Sys.argv.(1) in
  Unix.sleepf delay;
  Runtime_events.start ();
  (* Stay alive for the parent to trace, but do not outlive a test that has
     abandoned us. *)
  Unix.sleepf 30.0
