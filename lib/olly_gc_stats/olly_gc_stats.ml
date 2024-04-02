module H = Hdr_histogram
module Ts = Runtime_events.Timestamp

type ts = { mutable start_time : float; mutable end_time : float }

let total_gc_time = ref 0
let wall_time = { start_time = 0.; end_time = 0. }
let total_cpu_time = ref 0.
let domain_gc_times = Array.make 128 0

let lifecycle _domain_id _ts lifecycle_event _data =
  match lifecycle_event with
  | Runtime_events.EV_RING_START -> wall_time.start_time <- Unix.gettimeofday ()
  | Runtime_events.EV_RING_STOP ->
      wall_time.end_time <- Unix.gettimeofday ();
      let times = Unix.times () in
      total_cpu_time := times.tms_utime +. times.tms_cutime
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
  let to_sec x = float_of_int x /. 1000000000. in
  let real_time = wall_time.end_time -. wall_time.start_time in
  let gc_time = to_sec !total_gc_time in
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
    Printf.fprintf oc "Wall time (s):\t%.2f\n" real_time;
    Printf.fprintf oc "CPU time (s):\t%.2f\n" !total_cpu_time;
    Printf.fprintf oc "GC time (s):\t%.2f\n" gc_time;
    Printf.fprintf oc "GC overhead (%% of CPU time):\t%.2f%%\n"
      (gc_time /. !total_cpu_time *. 100.);
    Printf.fprintf oc "\n";
    Printf.fprintf oc "GC time per domain (s):\n";
    Array.iteri
      (fun i x ->
        if x > 0 then Printf.fprintf oc "Domain%d: \t%.2f\n" i (to_sec x))
      domain_gc_times;
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
        total_gc_time := !total_gc_time + latency;
        domain_gc_times.(ring_id) <- domain_gc_times.(ring_id) + latency
    | _ -> ()
  in
  let init = Fun.id in
  let cleanup () = print_percentiles json output hist in
  let open Olly_common.Launch in
  olly
    { empty_config with runtime_begin; runtime_end; lifecycle; init; cleanup }
    exec_args

let gc_stats_cmd =
  let open Cmdliner in
  let open Olly_common.Cli in
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

  let man =
    [
      `S Manpage.s_description;
      `P "Report the GC latency profile.";
      `I ("Wall time", "Real execution time of the program");
      `I ("CPU time", "Total CPU time across all domains");
      `I
        ( "GC time",
          "Total time spent by the program performing garbage collection \
           (major and minor)" );
      `I
        ( "GC overhead",
          "Percentage of time taken up by GC against the total execution time"
        );
      `I
        ( "GC time per domain",
          "Time spent by every domain performing garbage collection (major and \
           minor cycles). Domains are reported with their domain ID   (e.g. \
           `Domain0`)" );
      `I
        ( "GC latency profile",
          "Mean, standard deviation and percentile latency profile of GC \
           events." );
      `Blocks help_secs;
    ]
  in
  let doc = "Report the GC latency profile and stats." in
  let info = Cmd.info "gc-stats" ~doc ~sdocs ~man in
  Cmd.v info Term.(const gc_stats $ json_option $ output_option $ exec_args 0)
