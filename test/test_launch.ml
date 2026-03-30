let process_launch_failure () =
  let open Olly_common in
  let open Alcotest in
  let config = { Launch.log_wsize = None; dir = None } in
  match_raises "executable not found on path should not launch"
    (* Executable not found on path *)
    (function Launch.Fail _ -> true | _exn -> false)
    (fun () -> ignore (Launch.exec_process config [ "missing.exe" ]));

  match_raises "non-executable should not launch"
    (* File for exec_process is not an executable.
       Unix returns EACCES, Windows returns ENOEXEC. *)
    (function
      | Unix.Unix_error (Unix.EACCES, _, _) -> true
      | Unix.Unix_error (Unix.ENOEXEC, _, _) -> true
      | _exn -> false)
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
       let a = Launch.exec_process config [ "./run_endlessly.exe" ] in
       (* Check the child is alive using waitpid WNOHANG.
          Unix.kill with signal 0 is not supported on Windows. *)
       let launched = a.alive () in
       (* Clean up the child process so it doesn't leak.
          On Windows, open files cannot be deleted, so the orphan process
          would prevent dune from cleaning up its temp directory. *)
       (try Unix.kill a.pid Sys.sigkill
        with Unix.Unix_error _ | Invalid_argument _ -> ());
       (try ignore (Unix.waitpid [] a.pid) with Unix.Unix_error _ -> ());
       a.close ();
       launched
     with
    (* Any exceptions indicate a failure to launch *)
    | Unix.Unix_error (Unix.ENOENT, _, _) -> false
    | _exn ->
        Printf.printf "%s" (Printexc.to_string _exn);
        false)

let () =
  let open Alcotest in
  run "Runtime Events Tools"
    [
      ( "process",
        [
          test_case "process::launch success" `Quick process_launch;
          test_case "process::launch failure" `Quick process_launch_failure;
        ] );
    ]
