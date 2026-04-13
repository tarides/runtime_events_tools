module H = Hdr_histogram
module Ts = Runtime_events.Timestamp

type ts = { mutable start_time : float; mutable end_time : float }

(* Maximum number of domains that can be active concurrently.
   Defaults to 128 on 64-bit platforms and 16 on 32-bit platforms.

   This can be user configurable with OCAMLRUNPARAM=d=XXX
*)

let number_domains = 128
let wall_time = { start_time = 0.; end_time = 0. }
let domain_elapsed_times = Array.make number_domains 0.
let domain_gc_times = Array.make number_domains 0
let domain_minor_words = Array.make number_domains 0
let domain_promoted_words = Array.make number_domains 0
let domain_major_words = Array.make number_domains 0
let minor_collections = ref 0
let major_collections = ref 0
let forced_major_collections = ref 0
let compactions = ref 0

let lifecycle domain_id ts lifecycle_event _data =
  let ts = float_of_int Int64.(to_int @@ Ts.to_int64 ts) /. 1_000_000_000. in
  match lifecycle_event with
  | Runtime_events.EV_RING_START ->
      wall_time.start_time <- ts;
      domain_elapsed_times.(domain_id) <- ts
  | Runtime_events.EV_RING_STOP ->
      wall_time.end_time <- ts;
      domain_elapsed_times.(domain_id) <- ts -. domain_elapsed_times.(domain_id)
  | Runtime_events.EV_DOMAIN_SPAWN -> domain_elapsed_times.(domain_id) <- ts
  | Runtime_events.EV_DOMAIN_TERMINATE ->
      domain_elapsed_times.(domain_id) <- ts -. domain_elapsed_times.(domain_id)
  | _ -> ()

let print_table oc (data : string list list) =
  let column_widths =
    List.fold_left
      (fun widths row -> List.map2 max widths (List.map String.length row))
      (List.map String.length (List.hd data))
      (List.tl data)
  in
  let print_row row =
    let formatted_row =
      List.map2 (fun s w -> Printf.sprintf "%-*s" w s) row column_widths
    in
    Printf.fprintf oc "%s  \n" (String.concat "   " formatted_row)
  in

  List.iter print_row data

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

let print_percentiles json output hist =
  let to_sec x = float_of_int x /. 1_000_000_000. in
  let ms ns = ns /. 1_000_000. in

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
  let stddev_latency = H.stddev hist |> ms in
  let min_latency = float_of_int (H.min hist) |> ms in
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

  if json then (
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
    let domain_stats =
      let buf = Buffer.create 256 in
      Array.iteri
        (fun i (c, g) ->
          if c > 0. then (
            if Buffer.length buf > 0 then Buffer.add_char buf ',';
            Buffer.add_string buf
              (Printf.sprintf
                 {|"%d": {"wall_time": %.2f, "gc_time": %.2f, "gc_overhead": %.2f}|}
                 i c (to_sec g) (to_sec g *. 100. /. c))))
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
      {|{"wall_time": %.2f, "cpu_time": %.2f, "gc_time": %.2f, "gc_overhead": %.2f, "domain_stats": {%s}, "mean_latency": %f, "stddev_latency": %f, "min_latency": %.2f, "max_latency": %f, "distr_latency": {%s}, "allocations": {"total_heap": %.0f, "minor_heap": %.0f, "major_heap": %.0f, "promoted_words": %.0f, "promoted_pct": %.2f}, "domain_alloc_stats": {%s}, "collections": {"minor": %i, "major": %i, "forced_major": %i, "compactions": %i}}|}
      real_time !total_cpu_time total_gc_time gc_overhead domain_stats
      mean_latency stddev_latency min_latency max_latency distribs total_heap
      !minor_words !major_words !promoted_words promoted_pct domain_alloc_stats
      !minor_collections !major_collections !forced_major_collections
      !compactions)
  else (
    Printf.fprintf oc "\n";
    Printf.fprintf oc "Execution times:\n";
    Printf.fprintf oc "Wall time (s):\t%.2f\n" real_time;
    Printf.fprintf oc "CPU time (s):\t%.2f\n" !total_cpu_time;
    Printf.fprintf oc "GC time (s):\t%.2f\n" total_gc_time;
    Printf.fprintf oc "GC overhead (%% of CPU time):\t%.2f%%\n" gc_overhead;
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
          (float_of_int (H.value_at_percentile hist p) |> ms));
    Printf.fprintf oc "\n";
    print_global_allocation_stats oc;
    print_per_domain_stats oc;
    Printf.fprintf oc "Minor Gen: %i collections\n" !minor_collections;
    Printf.fprintf oc "Major Gen: %i collections %i forced collections\n"
      !major_collections !forced_major_collections;
    Printf.fprintf oc "Compactions: %i\n" !compactions)

let print_latency_only json output hist =
  let ms ns = ns /. 1_000_000. in

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

let latency poll_sleep json output runtime_events_dir exec_args =
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
        assert (H.record_value hist latency)
    | _ -> ()
  in
  let init = Fun.id in
  let cleanup () = print_latency_only json output hist in
  let open Olly_common.Launch in
  try
    `Ok
      (olly
         {
           empty_config with
           runtime_begin;
           runtime_end;
           init;
           cleanup;
           poll_sleep;
           runtime_events_dir;
         }
         exec_args)
  with Fail msg -> `Error (false, msg)

let gc_stats poll_sleep json output runtime_events_dir runtime_events_log_wsize
    exec_args =
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
    if phase == Runtime_events.EV_EXPLICIT_GC_COMPACT && ring_id == 0 then
      incr compactions;

    if phase == Runtime_events.EV_MINOR && ring_id == 0 then
      incr minor_collections;

    (* Runtime_events.EV_MAJOR seems to correspond to any GC collection,
       be more specific and use stop-the-world phase done at the end of
       a major GC cycle *)
    if phase == Runtime_events.EV_MAJOR_GC_STW && ring_id == 0 then
      incr major_collections;

    if
      (phase == Runtime_events.EV_EXPLICIT_GC_MAJOR
      || phase == Runtime_events.EV_EXPLICIT_GC_FULL_MAJOR)
      && ring_id == 0
    then incr forced_major_collections;

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
        domain_gc_times.(ring_id) <- domain_gc_times.(ring_id) + latency
    | _ -> ()
  in
  (* TODO: OCaml 5.5 adds EV_C_MINOR_PROMOTED_WORDS and
     EV_C_MINOR_ALLOCATED_WORDS (ocaml/ocaml#14189) which report in words
     directly, replacing the bytes-to-words conversion below. *)
  let bytes_per_word = Sys.word_size / 8 in
  let runtime_counter ring_id _ts counter_type value =
    match counter_type with
    | Runtime_events.EV_C_MINOR_PROMOTED ->
        (* Reported as bytes, convert to words *)
        domain_promoted_words.(ring_id) <-
          domain_promoted_words.(ring_id) + (value / bytes_per_word)
    | Runtime_events.EV_C_MINOR_ALLOCATED ->
        (* Reported as bytes, convert to words *)
        domain_minor_words.(ring_id) <-
          domain_minor_words.(ring_id) + (value / bytes_per_word)
    | Runtime_events.EV_C_MAJOR_ALLOCATED_WORDS ->
        (* Allocations to the major heap of this Domain in words,
          since the last major slice. *)
        domain_major_words.(ring_id) <- domain_major_words.(ring_id) + value
    | _ -> ()
  in

  let init = Fun.id in
  let cleanup () = print_percentiles json output hist in
  let open Olly_common.Launch in
  try
    `Ok
      (olly
         {
           empty_config with
           runtime_begin;
           runtime_end;
           runtime_counter;
           lifecycle;
           init;
           cleanup;
           poll_sleep;
           runtime_events_dir;
           runtime_events_log_wsize;
         }
         exec_args)
  with Fail msg -> `Error (false, msg)
