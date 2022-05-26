let () =
  if Array.length Sys.argv < 2 then
    Printf.printf "summarise_gc <executable> <args> ...\n"
  else begin
    (* Parse arguments and set up environment *)
    let executable_filename = Array.get Sys.argv 1 in
    let args = if Array.length Sys.argv > 2 then Array.sub Sys.argv 2 (Array.length Sys.argv) else [||] in
    let env = [Unix.environment (); [| "OCAML_RUNTIME_EVENTS_START=1"; "OCAML_RUNTIME_EVENTS_DIR=/tmp/" |]] |> Array.concat in
    let child_pid = Unix.create_process_env executable_filename args env Unix.stdin Unix.stdout Unix.stderr in
    (* Helper for callbacks *)
    let phase_starts = Hashtbl.create 4 in
    let phase_totals = Hashtbl.create 4 in
    let start_ts = ref Int64.zero in
    let end_ts = ref Int64.zero in
    let ts_to_ms ts = Int64.(div (Runtime_events.Timestamp.to_int64 ts) (of_int 1000)) in
    (* Callback functions for Runtime_events *)
    let lifecycle _ring_id ts event _opt =
      match event with
      | Runtime_events.EV_RING_START ->
        start_ts := (ts_to_ms ts)
      | Runtime_events.EV_RING_STOP ->
        end_ts := (ts_to_ms ts)
      | _ -> () in
    let runtime_end ring_id ts phase =
      match Hashtbl.find_opt phase_starts (ring_id, phase) with
      | Some(start_ts) ->
        let duration = Int64.sub (ts_to_ms ts) start_ts in
        Hashtbl.replace phase_totals phase (match Hashtbl.find_opt phase_totals phase with Some(x) -> Int64.add x duration | None -> duration)
      | None -> (* this can happen because we've lost events *) () in
    let runtime_begin ring_id ts phase =
      Hashtbl.replace phase_starts (ring_id, phase) (ts_to_ms ts) in
    let lost_events _ring_id _words_lost =
      Hashtbl.clear phase_starts in
    (* Read from the child process *)
    Unix.sleep 1;
    let cursor = Runtime_events.create_cursor (Some ("/tmp", child_pid)) in
    let callbacks = Runtime_events.Callbacks.create ~runtime_begin ~runtime_end ~lost_events ~lifecycle () in
    let child_alive () = match Unix.waitpid [ Unix.WNOHANG ] child_pid with
      | (0, _) -> true
      | (p, _) when p = child_pid -> false
      | (_, _) -> assert(false) in
    while child_alive () do begin
      Runtime_events.read_poll cursor callbacks None |> ignore
    end done;
    let run_duration_ms = Int64.to_int (Int64.sub !end_ts !start_ts) / 1000 in
    Printf.printf "Total duration:\t%dms\n" run_duration_ms;
    Printf.printf "=============================\n";
    Hashtbl.iter (fun phase total ->
      Runtime_events.(match phase with
      | EV_MAJOR | EV_MINOR | EV_STW_LEADER | EV_STW_HANDLER | EV_MINOR_LOCAL_ROOTS_PROMOTE | EV_MAJOR_SWEEP | EV_MAJOR_MARK | EV_MAJOR_FINISH_CYCLE ->
        let total_ms = (Int64.to_int total) / 1000 in
        Printf.printf "%dms (%d%%)\t%s\n" total_ms ((100 * total_ms) / run_duration_ms) (Runtime_events.runtime_phase_name phase)
      | _ -> ()
      )
    ) phase_totals
  end