let () =
  if Array.length Sys.argv < 3 then
    Printf.eprintf "%s <trace_filename> <executable> <args> ...\n" Sys.argv.(0)
  else begin
    (* Parse arguments and set up environment *)
    let trace_filename = Sys.argv.(1) in
    let trace_file = open_out trace_filename in
    Printf.fprintf trace_file "[";
    let executable_filename = Sys.argv.(2) in
    let args = if Array.length Sys.argv > 3 then Array.sub Sys.argv 2 (Array.length Sys.argv - 2) else [||] in
    (* Set the temp directory. We should make this configurable. *)
    let tmp_dir = Filename.get_temp_dir_name () in
    let env = [Unix.environment (); [| "OCAML_RUNTIME_EVENTS_START=1"; "OCAML_RUNTIME_EVENTS_DIR=" ^ tmp_dir; "OCAML_RUNTIME_EVENTS_PRESERVE=1" |]] |> Array.concat in
    let child_pid = Unix.create_process_env executable_filename args env Unix.stdin Unix.stdout Unix.stderr in
    (* Helper for callbacks *)
    let ts_to_ms ts = Int64.(div (Runtime_events.Timestamp.to_int64 ts) (of_int 1000)) in
    (* Callback functions for Runtime_events *)
    let runtime_begin ring_id ts phase =
      Printf.fprintf trace_file "{\"name\": \"%s\", \"cat\": \"PERF\", \"ph\":\"B\", \"ts\":%Ld, \"pid\": %d, \"tid\": %d},\n"
        (Runtime_events.runtime_phase_name phase) (ts_to_ms ts) ring_id ring_id;
      flush trace_file in
    let runtime_end ring_id ts phase =
      Printf.fprintf trace_file "{\"name\": \"%s\", \"cat\": \"PERF\", \"ph\":\"E\", \"ts\":%Ld, \"pid\": %d, \"tid\": %d},\n"
        (Runtime_events.runtime_phase_name phase) (ts_to_ms ts) ring_id ring_id;
      flush trace_file in
    (* Read from the child process *)
    Unix.sleep 1;
    let cursor = Runtime_events.create_cursor (Some (tmp_dir, child_pid)) in
    let callbacks = Runtime_events.Callbacks.create ~runtime_begin ~runtime_end () in
    let child_alive () = match Unix.waitpid [ Unix.WNOHANG ] child_pid with
      | (0, _) -> true
      | (p, _) when p = child_pid -> false
      | (_, _) -> assert(false) in
    while child_alive () do begin
      Runtime_events.read_poll cursor callbacks None |> ignore
    end done;
    (* Now we're done, we need to remove the ring buffers ourselves because we
      told the child process not to remove them *)
    let ring_file =
        Filename.concat tmp_dir (string_of_int child_pid ^ ".events") in
    Unix.unlink ring_file
  end

