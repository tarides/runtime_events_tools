let process_launch_failure () =
  let open Olly_common in
  let open Alcotest in
  let config = { Launch.log_wsize = None; dir = None } in
  match_raises "executable not found on path should not launch"
    (* Executable not found on path *)
    (function Launch.Fail _ -> true | _exn -> false)
    (fun () -> ignore (Launch.exec_process config [ "missing.exe" ]));

  match_raises "non-executable should not launch"
    (* File for exec_process is not an executable. The errno differs across
       platforms (EACCES on Unix, ENOEXEC on Windows), but [exec_process]
       reports either as [Fail]. *)
    (function Launch.Fail _ -> true | _exn -> false)
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
   (validating its code signature) before running any OCaml code.
   [run_slow_start.exe] emulates that by creating its ring buffer itself, half
   a second in, which keeps the pid, and hence the name of the ring file,
   unchanged. We launch it here rather than through [exec_process] because the
   latter always sets OCAML_RUNTIME_EVENTS_START, which would have the runtime
   create the ring buffer before the child ran any code of its own. *)
let process_launch_slow_start () =
  let open Olly_common in
  let delay = 0.5 in
  let dir = Filename.get_temp_dir_name () |> Unix.realpath in
  let executable = "./run_slow_start.exe" in
  let env =
    (* No OCAML_RUNTIME_EVENTS_START: the child's own [Runtime_events.start]
       is what creates the ring buffer. *)
    Array.append
      [| "OCAML_RUNTIME_EVENTS_DIR=" ^ dir; "OCAML_RUNTIME_EVENTS_PRESERVE=1" |]
      (Unix.environment () |> Array.to_seq
      |> Seq.filter (fun entry ->
             not (String.starts_with ~prefix:"OCAML_RUNTIME_EVENTS_" entry))
      |> Array.of_seq)
  in
  let launched = Unix.gettimeofday () in
  let handle =
    Platform.create_process_env executable
      [| executable; string_of_float delay |]
      env Unix.stdin Unix.stdout Unix.stderr
  in
  (* The child's own [Unix.getpid] is not the pid the runtime names the ring
     file after on Windows. The handle is. *)
  let pid = Platform.pid_of_handle handle in
  let ring_file = Filename.concat dir (string_of_int pid ^ ".events") in
  let remove_ring () = try Sys.remove ring_file with Sys_error _ -> () in
  match Launch.create_cursor_when_ready ~dir ~pid ~handle ~executable with
  | cursor ->
      Fun.protect
        ~finally:(fun () ->
          (* Neither side may still map the ring file for Windows to let us
             delete it. *)
          Runtime_events.free_cursor cursor;
          ignore (Platform.terminate_and_reap handle);
          remove_ring ())
        (fun () ->
          (* Usable, not merely created. *)
          ignore
            (Runtime_events.read_poll cursor
               (Runtime_events.Callbacks.create ())
               None);
          Alcotest.(check bool)
            "the ring buffer was not there for the taking at launch" true
            (Unix.gettimeofday () -. launched >= delay))
  | exception exn ->
      (* [create_cursor_when_ready] has reaped the child on every path that
         raises. *)
      remove_ring ();
      raise exn

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
