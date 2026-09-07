let process_launch_failure () =
  let open Olly_common in
  let open Alcotest in
  let config = { Launch.log_wsize = None; dir = None } in
  match_raises "executable not found on path should not launch"
    (* Executable not found on path *)
    (function Launch.Fail _ -> true | _exn -> false)
    (fun () -> ignore (Launch.exec_process config [ "missing.exe" ]));

  match_raises "non-executable should not launch"
    (* File for exec_process is not an executable *)
    (function Unix.Unix_error (Unix.EACCES, _, _) -> true | _exn -> false)
    (fun () -> ignore (Launch.exec_process config [ "./run_endlessly.ml" ]));

  match_raises "empty executable string should not launch"
    (* Empty executable string provided *)
    (function Launch.Fail _ -> true | _exn -> false)
    (fun () -> ignore (Launch.exec_process config [ "" ]))

let process_launch () =
  let open Olly_common in
  let config = { Launch.log_wsize = None; dir = None } in
  Alcotest.(check bool)
    "process should launch" true
    (try
       let child = Launch.exec_process config [ "./run_endlessly.exe" ] in
       (* [close] terminates it: left running, it would outlive the test and
          hold the inherited stdout open, hanging whoever reads it (dune). *)
       Fun.protect ~finally:child.close (fun () -> child.alive ())
     with
    (* Any exceptions indicate a failure to launch *)
    | Unix.Unix_error (Unix.ENOENT, _, _) -> false
    | _exn ->
        Printf.printf "%s" (Printexc.to_string _exn);
        false)

(* A child can take much longer than one might expect to get to the point
   where it initialises its ring buffers: on macOS, the first execution of a
   freshly built binary spends a few hundred milliseconds in the kernel
   (validating its code signature) before running any OCaml code. Emulate a
   slow start with a shell that sleeps and then execs the traced program,
   which keeps the pid, and hence the name of the ring file, unchanged. *)
let process_launch_slow_start () =
  let open Olly_common in
  let config = { Launch.log_wsize = None; dir = None } in
  let child =
    Launch.exec_process config
      [ "/bin/sh"; "-c"; "sleep 0.5; exec ./run_endlessly.exe" ]
  in
  Fun.protect ~finally:child.close (fun () ->
      Alcotest.(check bool)
        "process with a slow start should be traced" true (child.alive ()))

let () =
  let open Alcotest in
  run "Runtime Events Tools"
    [
      ( "process",
        [
          test_case "process::launch success" `Quick process_launch;
          test_case "process::launch failure" `Quick process_launch_failure;
          test_case "process::launch slow start" `Quick
            process_launch_slow_start;
        ] );
    ]
