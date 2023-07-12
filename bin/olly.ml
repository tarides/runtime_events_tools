module H = Hdr_histogram
module Ts = Runtime_events.Timestamp
open Cmdliner

(** Trace format - either json or Fuchsia Trace Format (filenames typically ending in
   .fxt). Fuchsia is a binary format viewable in Perfetto. *)
type trace_format = Json | Fuchsia

let total_gc_time = ref 0
let start_time = ref 0.0
let end_time = ref 0.0

let lifecycle _domain_id _ts lifecycle_event _data =
  match lifecycle_event with
  | Runtime_events.EV_RING_START -> start_time := Unix.gettimeofday ()
  | Runtime_events.EV_RING_STOP -> end_time := Unix.gettimeofday ()
  | _ -> ()

let print_percentiles json output hist =
  let ms ns = ns /. 1000000. in
  let mean_latency = H.mean hist |> ms
  and max_latency = float_of_int (H.max hist) |> ms in
  let percentiles =
    [|
      25.0;
      50.0;
      60.0;
      70.0;
      75.0;
      80.0;
      85.0;
      90.0;
      95.0;
      96.0;
      97.0;
      98.0;
      99.0;
      99.9;
      99.99;
      99.999;
      99.9999;
      100.0;
    |]
  in
  let oc = match output with Some s -> open_out s | None -> stderr in
  let total_time = !end_time -. !start_time in
  let gc_time = float_of_int !total_gc_time /. 1000000000. in
  if json then
    let distribs =
      List.init (Array.length percentiles) (fun i ->
          let percentile = percentiles.(i) in
          let value =
            H.value_at_percentile hist percentiles.(i)
            |> float_of_int |> ms |> string_of_float
          in
          Printf.sprintf "\"%.4f\": %s" percentile value)
      |> String.concat ","
    in
    Printf.fprintf oc
      {|{"mean_latency": %f, "max_latency": %f, "distr_latency": {%s}}|}
      mean_latency max_latency distribs
  else (
    Printf.fprintf oc "\n";
    Printf.fprintf oc "Execution times:\n";
    Printf.fprintf oc "Wall time (s):\t%.2f\n" total_time;
    Printf.fprintf oc "GC time (s):\t%.2f\n" gc_time;
    Printf.fprintf oc "GC overhead (%% of wall time):\t%.2f%%\n"
      (gc_time /. total_time *. 100.);
    Printf.fprintf oc "\n";
    Printf.fprintf oc "GC latency profile:\n";
    Printf.fprintf oc "#[Mean (ms):\t%.2f,\t Stddev (ms):\t%.2f]\n" mean_latency
      (H.stddev hist |> ms);
    Printf.fprintf oc "#[Min (ms):\t%.2f,\t max (ms):\t%.2f]\n"
      (float_of_int (H.min hist) |> ms)
      max_latency;
    Printf.fprintf oc "\n";
    Printf.fprintf oc "Percentile \t Latency (ms)\n";
    Fun.flip Array.iter percentiles (fun p ->
        Printf.fprintf oc "%.4f \t %.2f\n" p
          (float_of_int (H.value_at_percentile hist p) |> ms)))

let lost_events ring_id num =
  Printf.eprintf "[ring_id=%d] Lost %d events\n%!" ring_id num

let olly ?extra ~runtime_begin ~runtime_end ~cleanup ~lifecycle ~init exec_args
    =
  let argsl = String.split_on_char ' ' exec_args in
  let executable_filename = List.hd argsl in

  (* Set the temp directory. We should make this configurable. *)
  let tmp_dir = Filename.get_temp_dir_name () ^ "/" in
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

let trace format trace_filename exec_args =
  match format with
  | Json ->
      let trace_file = open_out trace_filename in
      let ts_to_us ts = Int64.(div (Ts.to_int64 ts) (of_int 1000)) in
      let runtime_begin ring_id ts phase =
        Printf.fprintf trace_file
          "{\"name\": \"%s\", \"cat\": \"PERF\", \"ph\":\"B\", \"ts\":%Ld, \
           \"pid\": %d, \"tid\": %d},\n"
          (Runtime_events.runtime_phase_name phase)
          (ts_to_us ts) ring_id ring_id;
        flush trace_file
      in
      let runtime_end ring_id ts phase =
        Printf.fprintf trace_file
          "{\"name\": \"%s\", \"cat\": \"PERF\", \"ph\":\"E\", \"ts\":%Ld, \
           \"pid\": %d, \"tid\": %d},\n"
          (Runtime_events.runtime_phase_name phase)
          (ts_to_us ts) ring_id ring_id;
        flush trace_file
      in
      let init () =
        (* emit prefix in the tracefile *)
        Printf.fprintf trace_file "["
      in
      let cleanup () = close_out trace_file in
      olly ~runtime_begin ~runtime_end ~init ~lifecycle ~cleanup exec_args
  | Fuchsia ->
      let open Tracing in
      let trace_file =
        Trace.create_for_file ~base_time:None ~filename:trace_filename
      in
      (* Note: Fuchsia timestamps are nanoseconds
         https://fuchsia.dev/fuchsia-src/reference/tracing/trace-format#timestamps so no need
         to scale as is done in [ts_to_us] above *)
      let ts_to_int ts = ts |> Ts.to_int64 |> Int64.to_int in
      let int_to_span i = Core.Time_ns.Span.of_int_ns i in
      let doms =
        (* Allocate all domains before starting to write trace; as above we identify the
           thread id with the ring_id used by runtime events. This pre-allocation consumes
           about 7kB in the trace file. *)
        let max_doms = 128 in
        Array.init max_doms (fun i ->
            (* Use a different pid for each domain *)
            Trace.allocate_thread trace_file ~pid:i
              ~name:(Printf.sprintf "Ring_id %d" i))
      in
      let runtime_begin ring_id ts phase =
        let thread = doms.(ring_id) in
        Trace.write_duration_begin trace_file ~args:[] ~thread ~category:"PERF"
          ~name:(Runtime_events.runtime_phase_name phase)
          ~time:(ts |> ts_to_int |> int_to_span)
      in
      let runtime_end ring_id ts phase =
        let thread = doms.(ring_id) in
        Trace.write_duration_end trace_file ~args:[] ~thread ~category:"PERF"
          ~name:(Runtime_events.runtime_phase_name phase)
          ~time:(ts |> ts_to_int |> int_to_span)
      in
      let extra = Olly_custom_events.v trace_file doms in
      let init () = () in
      let cleanup () = Trace.close trace_file in
      olly ~extra ~runtime_begin ~runtime_end ~init ~lifecycle ~cleanup
        exec_args

let gc_stats json output exec_args =
  let current_event = Hashtbl.create 13 in
  let hist =
    H.init ~lowest_discernible_value:10 ~highest_trackable_value:10_000_000_000
      ~significant_figures:3
  in
  let is_gc_phase phase =
    match phase with
    | Runtime_events.EV_MAJOR | Runtime_events.EV_STW_LEADER
    | Runtime_events.EV_INTERRUPT_REMOTE ->
        true
    | _ -> false
  in
  let runtime_begin ring_id ts phase =
    if is_gc_phase phase then
      match Hashtbl.find_opt current_event ring_id with
      | None -> Hashtbl.add current_event ring_id (phase, Ts.to_int64 ts)
      | _ -> ()
  in
  let runtime_end ring_id ts phase =
    match Hashtbl.find_opt current_event ring_id with
    | Some (saved_phase, saved_ts) when saved_phase = phase ->
        Hashtbl.remove current_event ring_id;
        let latency = Int64.to_int (Int64.sub (Ts.to_int64 ts) saved_ts) in
        assert (H.record_value hist latency);
        total_gc_time := !total_gc_time + latency
    | _ -> ()
  in
  let init = Fun.id in
  let cleanup () = print_percentiles json output hist in
  olly ~runtime_begin ~runtime_end ~init ~lifecycle ~cleanup exec_args

let help man_format cmds topic =
  match topic with
  | None -> `Help (`Pager, None) (* help about the program. *)
  | Some topic -> (
      let topics = "topics" :: cmds in
      let conv, _ = Cmdliner.Arg.enum (List.rev_map (fun s -> (s, s)) topics) in
      match conv topic with
      | `Error e -> `Error (false, e)
      | `Ok t when t = "topics" ->
          List.iter print_endline topics;
          `Ok ()
      | `Ok t when List.mem t cmds -> `Help (man_format, Some t)
      | `Ok _t ->
          let page =
            ((topic, 7, "", "", ""), [ `S topic; `P "Say something" ])
          in
          `Ok (Cmdliner.Manpage.print man_format Format.std_formatter page))

let () =
  (* Help sections common to all commands *)
  let help_secs =
    [
      `S Manpage.s_common_options;
      `P "These options are common to all commands.";
      `S "MORE HELP";
      `P "Use $(mname) $(i,COMMAND) --help for help on a single command.";
      `Noblank;
      `S Manpage.s_bugs;
      `P "Check bug reports at http://bugs.example.org.";
    ]
  in

  (* Commands *)
  let sdocs = Manpage.s_common_options in

  let exec_args p =
    let doc =
      "Executable (and its arguments) to trace. If the executable takes\n\
      \              arguments, wrap quotes around the executable and its \
       arguments.\n\
      \              For example, olly '<exec> <arg_1> <arg_2> ... <arg_n>'."
    in
    Arg.(required & pos p (some string) None & info [] ~docv:"EXECUTABLE" ~doc)
  in

  let format_option =
    let doc =
      "Format of the target trace, either \"json\" (for Chrome tracing) or \
       \"fuchsia\" (Perfetto)."
    in
    Arg.(
      value
      & opt (enum [ ("json", Json); ("fuchsia", Fuchsia) ]) Fuchsia
      & info [ "f"; "format" ] ~docv:"format" ~doc)
  in

  let trace_cmd =
    let trace_filename =
      let doc = "Target trace file name." in
      Arg.(required & pos 0 (some string) None & info [] ~docv:"TRACEFILE" ~doc)
    in
    let man =
      [
        `S Manpage.s_description;
        `P "Save the runtime trace to file.";
        `Blocks help_secs;
      ]
    in
    let doc = "Save the runtime trace to file." in
    let info = Cmd.info "trace" ~doc ~sdocs ~man in
    Cmd.v info Term.(const trace $ format_option $ trace_filename $ exec_args 1)
  in

  let json_option =
    let doc = "Print the output in json instead of human-readable format." in
    Arg.(value & flag & info [ "json" ] ~docv:"json" ~doc)
  in

  let output_option =
    let doc =
      "Redirect the output of `olly` to specified file. The output of the \
       command is not redirected."
    in
    Arg.(
      value
      & opt (some string) None
      & info [ "o"; "output" ] ~docv:"output" ~doc)
  in

  let gc_stats_cmd =
    let man =
      [
        `S Manpage.s_description;
        `P "Report the GC latency profile.";
        `Blocks help_secs;
      ]
    in
    let doc = "Report the GC latency profile." in
    let info = Cmd.info "gc-stats" ~doc ~sdocs ~man in
    Cmd.v info Term.(const gc_stats $ json_option $ output_option $ exec_args 0)
  in

  let help_cmd =
    let topic =
      let doc = "The topic to get help on. $(b,topics) lists the topics." in
      Arg.(value & pos 0 (some string) None & info [] ~docv:"TOPIC" ~doc)
    in
    let doc = "Display help about olly and olly commands." in
    let man =
      [
        `S Manpage.s_description;
        `P "Prints help about olly commands and other subjects…";
        `Blocks help_secs;
      ]
    in
    let info = Cmd.info "help" ~doc ~man in
    Cmd.v info
      Term.(ret (const help $ Arg.man_format $ Term.choice_names $ topic))
  in

  let main_cmd =
    let doc = "An observability tool for OCaml programs" in
    let info = Cmd.info "olly" ~doc ~sdocs in
    Cmd.group info [ trace_cmd; gc_stats_cmd; help_cmd ]
  in

  exit (Cmd.eval main_cmd)
