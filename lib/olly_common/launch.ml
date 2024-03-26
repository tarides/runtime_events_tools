let lost_events ring_id num =
  Printf.eprintf "[ring_id=%d] Lost %d events\n%!" ring_id num

let olly ?extra ~runtime_begin ~runtime_end ~cleanup ~lifecycle ~init exec_args
    =
  let argsl = String.split_on_char ' ' exec_args in
  let executable_filename = List.hd argsl in

  (* TODO Set the temp directory. We should make this configurable. *)
  let tmp_dir = Filename.get_temp_dir_name () |> Unix.realpath in
  let env =
    Array.append
      [|
        "OCAML_RUNTIME_EVENTS_START=1";
        "OCAML_RUNTIME_EVENTS_DIR=" ^ tmp_dir;
        "OCAML_RUNTIME_EVENTS_PRESERVE=1";
      |]
      (Unix.environment ())
  in
  let child_pid =
    Unix.create_process_env executable_filename (Array.of_list argsl) env
      Unix.stdin Unix.stdout Unix.stderr
  in

  init ();
  (* Read from the child process *)
  Unix.sleepf 0.1;
  let cursor = Runtime_events.create_cursor (Some (tmp_dir, child_pid)) in
  let callbacks =
    Runtime_events.Callbacks.create ~runtime_begin ~runtime_end ~lifecycle
      ~lost_events ()
    |> Option.value extra ~default:Fun.id
  in
  let child_alive () =
    match Unix.waitpid [ Unix.WNOHANG ] child_pid with
    | 0, _ -> true
    | p, _ when p = child_pid -> false
    | _, _ -> assert false
  in
  while child_alive () do
    Runtime_events.read_poll cursor callbacks None |> ignore;
    Unix.sleepf 0.1 (* Poll at 10Hz *)
  done;

  (* Do one more poll in case there are any remaining events we've missed *)
  Runtime_events.read_poll cursor callbacks None |> ignore;

  (* Now we're done, we need to remove the ring buffers ourselves because we
      told the child process not to remove them *)
  let ring_file =
    Filename.concat tmp_dir (string_of_int child_pid ^ ".events")
  in
  Unix.unlink ring_file;
  cleanup ()
