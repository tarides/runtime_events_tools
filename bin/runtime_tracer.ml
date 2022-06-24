module H = Hdr_histogram
module Ts = Runtime_events.Timestamp
open Cmdliner


let print_percentiles hist =
  let ms ns = ns /. 1000000. in
  Printf.eprintf "\n";
  Printf.eprintf "#[Mean (ms):\t%.2f,\t Stddev (ms):\t%.2f]\n"
    (H.mean hist |> ms) (H.stddev hist |> ms);
  Printf.eprintf "#[Min (ms):\t%.2f,\t max (ms):\t%.2f]\n"
    (float_of_int (H.min hist) |> ms) (float_of_int (H.max hist) |> ms);

  Printf.eprintf "\n";
  let percentiles = [| 50.0; 75.0; 90.0; 99.0; 99.9; 99.99; 99.999; 100.0 |] in
  Printf.eprintf "percentile \t latency (ms)\n";
  Fun.flip Array.iter percentiles (fun p -> Printf.eprintf "%.4f \t %.2f\n" p
    (float_of_int (H.value_at_percentile hist p) |> ms))

let olly trace_filename executable_filename args =

let () =
  let trace_filename =
    let doc = "Save the trace in $(docv) file in Chrome trace format." in
    Arg.(value & opt (some string) None &
         info ["t"; "trace-file"] ~docv:"TRACEFILE" ~doc)
  in

  let executable_filename =
    let doc = "Executable to trace." in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"EXECUTABLE" ~doc)
  in

  let args =
    let doc = "Arguments." in
    Arg.(value & pos_right 0 string [] & info [] ~docv:"ARGUMENTS")
  in

  let olly_t = Term.(const chorus $ count $ msg)
  let cmd =
    let doc = "trace an OCaml executable" in
    let info = Cmd.info "chorus" ~version:"%‌%VERSION%%" ~doc ~man in
    Cmd.v info chorus_t



  if Array.length Sys.argv < 3 then
    Printf.eprintf "%s <trace_filename> <executable> <args> ...\n" Sys.argv.(0)
  else begin

    (* Parse arguments and set up environment *)
    let trace_filename = Sys.argv.(1) in
    let trace_file = open_out trace_filename in
    Printf.fprintf trace_file "[";
    let executable_filename = Sys.argv.(2) in
    let args =
      if Array.length Sys.argv > 3 then
        Array.sub Sys.argv 2 (Array.length Sys.argv - 2)
      else [||]
    in
    let current_event = Hashtbl.create 13 in
    let hist =
      H.init ~lowest_discernible_value:10
             ~highest_trackable_value:10_000_000_000
             ~significant_figures:3
    in

    (* Set the temp directory. We should make this configurable. *)
    let tmp_dir = Filename.get_temp_dir_name ()  ^ "/" in
    let env = Array.append [| "OCAML_RUNTIME_EVENTS_START=1";
                              "OCAML_RUNTIME_EVENTS_DIR=" ^ tmp_dir;
                              "OCAML_RUNTIME_EVENTS_PRESERVE=1" |]
                           (Unix.environment ())
    in
    let child_pid =
      Unix.create_process_env executable_filename args env
                              Unix.stdin Unix.stdout Unix.stderr
    in

    (* Helper for callbacks *)
    let ts_to_us ts =
      Int64.(div (Ts.to_int64 ts) (of_int 1000))
    in

    (* Callback functions for Runtime_events *)
    let runtime_begin ring_id ts phase =
      Printf.fprintf trace_file "{\"name\": \"%s\", \"cat\": \"PERF\", \"ph\":\"B\", \"ts\":%Ld, \"pid\": %d, \"tid\": %d},\n"
        (Runtime_events.runtime_phase_name phase) (ts_to_us ts) ring_id ring_id;
      flush trace_file;
      match Hashtbl.find_opt current_event ring_id with
      | None -> Hashtbl.add current_event ring_id (phase, Ts.to_int64 ts)
      | _ -> ()
    in

    let runtime_end ring_id ts phase =
      Printf.fprintf trace_file "{\"name\": \"%s\", \"cat\": \"PERF\", \"ph\":\"E\", \"ts\":%Ld, \"pid\": %d, \"tid\": %d},\n"
        (Runtime_events.runtime_phase_name phase) (ts_to_us ts) ring_id ring_id;
      flush trace_file;
      match Hashtbl.find_opt current_event ring_id with
      | Some (saved_phase, saved_ts) when (saved_phase = phase) ->
          Hashtbl.remove current_event ring_id;
          let latency =
            Int64.to_int (Int64.sub (Ts.to_int64 ts) saved_ts)
          in
          assert (H.record_value hist latency)
      | _ -> ()
    in

    (* Read from the child process *)
    Unix.sleep 1;
    let cursor = Runtime_events.create_cursor (Some (tmp_dir, child_pid)) in
    let callbacks = Runtime_events.Callbacks.create ~runtime_begin ~runtime_end () in
    let child_alive () = match Unix.waitpid [ Unix.WNOHANG ] child_pid with
      | (0, _) -> true
      | (p, _) when p = child_pid -> false
      | (_, _) -> assert(false) in
    while child_alive () do begin
      Runtime_events.read_poll cursor callbacks None |> ignore;
      Unix.sleepf 0.1 (* Poll at 10Hz *)
    end done;

    (* Do one more poll in case there are any remaining events we've missed *)
    Runtime_events.read_poll cursor callbacks None |> ignore;

    print_percentiles hist;

    (* Now we're done, we need to remove the ring buffers ourselves because we
       told the child process not to remove them *)
    let ring_file =
      Filename.concat tmp_dir (string_of_int child_pid ^ ".events")
    in
    Unix.unlink ring_file
  end
