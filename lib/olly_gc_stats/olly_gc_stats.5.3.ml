include Olly_gc_stats_common

let domain_major_words = Array.make number_domains 0

let print_global_allocation_stats oc =
  Printf.fprintf oc "GC allocations (in words): \n";
  let minor_words = ref 0.0 in
  let major_words = ref 0.0 in
  let promoted_words = ref 0.0 in
  Array.iteri
    (fun i v ->
      minor_words := !minor_words +. float_of_int v;
      major_words := !major_words +. float_of_int domain_major_words.(i);
      promoted_words :=
        !promoted_words +. float_of_int domain_promoted_words.(i))
    domain_minor_words;
  Printf.fprintf oc "Total heap:\t %.0f\n" (!minor_words -. !promoted_words);
  Printf.fprintf oc "Total heap:\t %.0f\n"
    (!minor_words -. !promoted_words +. !major_words);
  Printf.fprintf oc "Minor heap:\t %.0f\n" !minor_words;
  Printf.fprintf oc "Major heap:\t %.0f\n" !major_words;
  Printf.fprintf oc "Promoted words:\t %.0f (%.2f%%)\n" !promoted_words
    (!promoted_words /. !minor_words *. 100.0);
  Printf.fprintf oc "\n"

let print_per_domain_stats oc =
  Printf.fprintf oc "Per domain stats: \n";
  let data =
    ref [ [ "Domain"; "Total"; "Minor"; "Promoted"; "Major"; "Promoted(%)" ] ]
  in

  Array.iteri
    (fun i (domain_major_word, (domain_minor_word, domain_promoted_word)) ->
      if domain_major_word > 0 then
        data :=
          List.append !data
            [
              [
                string_of_int i;
                string_of_int
                  (domain_minor_word - domain_promoted_word + domain_major_word);
                string_of_int domain_minor_word;
                string_of_int domain_promoted_word;
                string_of_int domain_major_word;
                Printf.sprintf "%.2f"
                  (float_of_int domain_promoted_word
                  /. float_of_int domain_minor_word
                  *. 100.0);
              ];
            ])
    (Array.combine domain_minor_words domain_promoted_words
    |> Array.combine domain_major_words);
  print_table oc !data

let print_percentiles json output =
  let to_sec x = float_of_int x /. 1_000_000_000. in
  let ms ns = ns /. 1_000_000. in
  let outliers_count = Gc_counter.outliers_count () in
  let outliers_max = Gc_counter.outliers_max () in
  let outlier_mean_ms =
    if outliers_count = 0 then 0.
    else
      float_of_int (Gc_counter.outliers_total ()) /. float_of_int outliers_count
      |> ms
  in

  let mean_latency = Gc_counter.hist_mean () |> ms
  and max_latency = float_of_int (Gc_counter.hist_max ()) |> ms in
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
  let real_time = wall_time.end_time -. wall_time.start_time in
  let total_gc_time = to_sec @@ Array.fold_left ( + ) 0 domain_gc_times in

  let total_cpu_time = ref 0. in
  let ap = Array.combine domain_elapsed_times domain_gc_times in
  Array.iteri
    (fun i (cpu_time, gc_time) ->
      if gc_time > 0 && cpu_time = 0. then
        Printf.fprintf stderr
          "[Olly] Warning: Domain %d has GC time but no CPU time\n" i
      else total_cpu_time := !total_cpu_time +. cpu_time)
    ap;

  let gc_overhead = total_gc_time /. !total_cpu_time *. 100. in
  let stddev_latency = Gc_counter.hist_stddev () |> ms in
  let min_latency = float_of_int (Gc_counter.hist_min ()) |> ms in
  let minor_words = ref 0.0 in
  let major_words = ref 0.0 in
  let promoted_words = ref 0.0 in
  Array.iteri
    (fun i v ->
      minor_words := !minor_words +. float_of_int v;
      major_words := !major_words +. float_of_int domain_major_words.(i);
      promoted_words :=
        !promoted_words +. float_of_int domain_promoted_words.(i))
    domain_minor_words;
  let total_heap = !minor_words -. !promoted_words +. !major_words in
  let promoted_pct = !promoted_words /. !minor_words *. 100.0 in

  if json then
    let distribs =
      List.init (Array.length percentiles) (fun i ->
          let percentile = percentiles.(i) in
          let value =
            Gc_counter.hist_value_at_percentile percentiles.(i)
            |> float_of_int |> ms |> string_of_float
          in
          Printf.sprintf "\"%.4f\": %s" percentile value)
      |> String.concat ","
    in
    let domain_stats =
      let buf = Buffer.create 256 in
      Array.iteri
        (fun i (c, g) ->
          if c > 0. then (
            if Buffer.length buf > 0 then Buffer.add_char buf ',';
            Buffer.add_string buf
              (Printf.sprintf
                 {|"%d": {"wall_time": %.2f, "gc_time": %.2f, "gc_overhead": %.2f}|}
                 i c (to_sec g)
                 (to_sec g *. 100. /. c))))
        (Array.combine domain_elapsed_times domain_gc_times);
      Buffer.contents buf
    in
    let domain_alloc_stats =
      let buf = Buffer.create 256 in
      Array.iteri
        (fun i (domain_major_word, (domain_minor_word, domain_promoted_word)) ->
          if domain_major_word > 0 then (
            if Buffer.length buf > 0 then Buffer.add_char buf ',';
            Buffer.add_string buf
              (Printf.sprintf
                 {|"%d": {"total": %d, "minor": %d, "promoted": %d, "major": %d, "promoted_pct": %.2f}|}
                 i
                 (domain_minor_word - domain_promoted_word + domain_major_word)
                 domain_minor_word domain_promoted_word domain_major_word
                 (float_of_int domain_promoted_word
                 /. float_of_int domain_minor_word
                 *. 100.0))))
        (Array.combine domain_minor_words domain_promoted_words
        |> Array.combine domain_major_words);
      Buffer.contents buf
    in
    Printf.fprintf oc
      {|{"version": 2, "wall_time": %.2f, "cpu_time": %.2f, "gc_time": %.2f, "gc_overhead": %.2f, "max_rss_kb": %d, "domain_stats": {%s}, "mean_latency": %f, "stddev_latency": %f, "min_latency": %.2f, "max_latency": %f, "distr_latency": {%s}, "outliers": {"count": %d, "mean_latency": %f, "max_latency": %f}, "allocations": {"total_heap": %.0f, "minor_heap": %.0f, "major_heap": %.0f, "promoted_words": %.0f, "promoted_pct": %.2f}, "domain_alloc_stats": {%s}, "collections": {"minor": %i, "major": %i, "forced_major": %i, "compactions": %i}}|}
      real_time !total_cpu_time total_gc_time gc_overhead
      (Olly_common.Max_rss.max_rss_kb rss_collector)
      domain_stats mean_latency stddev_latency min_latency max_latency distribs
      outliers_count outlier_mean_ms
      (float_of_int outliers_max |> ms)
      total_heap !minor_words !major_words !promoted_words promoted_pct
      domain_alloc_stats !minor_collections !major_collections
      !forced_major_collections !compactions
  else (
    Printf.fprintf oc "\n";
    Printf.fprintf oc "Execution times:\n";
    Printf.fprintf oc "Wall time (s):\t%.2f\n" real_time;
    Printf.fprintf oc "CPU time (s):\t%.2f\n" !total_cpu_time;
    Printf.fprintf oc "GC time (s):\t%.2f\n" total_gc_time;
    Printf.fprintf oc "GC overhead (%% of CPU time):\t%.2f%%\n" gc_overhead;
    Printf.fprintf oc "Max RSS (kB):\t%d\n"
      (Olly_common.Max_rss.max_rss_kb rss_collector);
    Printf.fprintf oc "\n";
    Printf.fprintf oc "Per domain stats:\n";
    let data = ref [ [ "Domain"; "Wall"; "GC(s)"; "GC(%)" ] ] in
    Array.iteri
      (fun i (c, g) ->
        if c > 0. then
          data :=
            List.append !data
              [
                [
                  string_of_int i;
                  Printf.sprintf "%.2f" c;
                  Printf.sprintf "%.2f" (to_sec g);
                  Printf.sprintf "%.2f" (to_sec g *. 100. /. c);
                ];
              ])
      (Array.combine domain_elapsed_times domain_gc_times);

    print_table oc !data;
    Printf.fprintf oc "\n";
    Printf.fprintf oc "GC latency profile:\n";
    Printf.fprintf oc "#[Mean (ms):\t%.2f,\t Stddev (ms):\t%.2f]\n" mean_latency
      stddev_latency;
    Printf.fprintf oc "#[Min (ms):\t%.2f,\t max (ms):\t%.2f]\n" min_latency
      max_latency;
    Printf.fprintf oc "\n";
    Printf.fprintf oc "Percentile \t Latency (ms)\n";
    Fun.flip Array.iter percentiles (fun p ->
        Printf.fprintf oc "%.4f \t %.2f\n" p
          (float_of_int (Gc_counter.hist_value_at_percentile p) |> ms));
    if outliers_count > 0 then
      Printf.fprintf oc
        "#[Beyond histogram (> %.0f ms):\t%d events,\t mean (ms):\t%.2f,\t max \
         (ms):\t%.2f]\n"
        (float_of_int highest_trackable_value |> ms)
        outliers_count outlier_mean_ms
        (float_of_int outliers_max |> ms);
    Printf.fprintf oc "\n";
    print_global_allocation_stats oc;
    print_per_domain_stats oc;
    Printf.fprintf oc "Minor Gen: %i collections\n" !minor_collections;
    Printf.fprintf oc "Major Gen: %i collections %i forced collections\n"
      !major_collections !forced_major_collections;
    Printf.fprintf oc "Compactions: %i\n" !compactions)

(* Copy the natively-accumulated state out of [Gc_counter] into the per-domain
   arrays and counters used by the reporting code above. *)
let collect_native_stats () =
  for i = 0 to number_domains - 1 do
    domain_minor_words.(i) <- Gc_counter.minor_words i;
    domain_promoted_words.(i) <- Gc_counter.promoted_words i;
    domain_major_words.(i) <- Gc_counter.major_words i;
    domain_gc_times.(i) <- Gc_counter.gc_time i;
    domain_elapsed_times.(i) <- Gc_counter.domain_elapsed i
  done;
  wall_time.start_time <- Gc_counter.wall_start ();
  wall_time.end_time <- Gc_counter.wall_end ();
  minor_collections := Gc_counter.minor_collections ();
  major_collections := Gc_counter.major_collections ();
  forced_major_collections := Gc_counter.forced_major_collections ();
  compactions := Gc_counter.compactions ()

let gc_stats poll_sleep rss_freq json output runtime_events_dir
    runtime_events_log_wsize exec_args =
  (* All event processing happens natively in [Gc_counter] (see
     gc_counter_stubs.c) to avoid the per-event OCaml callback dispatch that
     otherwise bottlenecks the consumer on bursty workloads. The OCaml cursor is
     not polled ([poll_cursor = false]); results are read out at cleanup. *)
  let init = Fun.id in
  let open Olly_common.Launch in
  let on_launch (child : subprocess) =
    Olly_common.Rss_poller.start ~pid:child.pid ~interval:rss_freq
  in
  let cleanup () =
    Olly_common.Max_rss.set rss_collector (Olly_common.Rss_poller.stop ());
    print_percentiles json output
  in
  try
    `Ok
      (olly
         {
           empty_config with
           init;
           cleanup;
           on_launch;
           on_poll = (fun () -> ignore (Gc_counter.poll ()));
           poll_cursor = false;
           poll_sleep;
           runtime_events_dir;
           runtime_events_log_wsize;
         }
         exec_args)
  with Fail msg -> `Error (false, msg)
