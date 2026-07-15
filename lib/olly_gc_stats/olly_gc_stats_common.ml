module H = Hdr_histogram
module Ts = Runtime_events.Timestamp

type ts = { mutable start_time : float; mutable end_time : float }

(* Maximum number of domains that can be active concurrently.
   Defaults to 128 on 64-bit platforms and 16 on 32-bit platforms.

   This can be user configurable with OCAMLRUNPARAM=d=XXX
*)
let number_domains = 128

(* Running summary of GC pauses that fall outside the histogram's range. *)
type outliers = { mutable count : int; mutable total : int; mutable max : int }

let make_outliers () = { count = 0; total = 0; max = 0 }

let make_hist () =
  H.init ~lowest_discernible_value:10 ~highest_trackable_value:10_000_000_000
    ~significant_figures:3

(* Largest GC pause (in nanoseconds) the latency histogram can track. Pauses
   beyond this are summarised separately. This should be calculated through the hist implementation 
   and the concrete arguments in [make_hist] *)
let highest_trackable_value = 2 lsl 34
let wall_time = { start_time = 0.; end_time = 0. }
let rss_collector = Olly_common.Max_rss.create ()
let domain_elapsed_times = Array.make number_domains 0.
let domain_gc_times = Array.make number_domains 0
let domain_minor_words = Array.make number_domains 0
let domain_promoted_words = Array.make number_domains 0
let minor_collections = ref 0
let major_collections = ref 0
let forced_major_collections = ref 0
let compactions = ref 0
let to_sec x = float_of_int x /. 1_000_000_000.
let ms ns = ns /. 1_000_000.
let mean_latency hist = H.mean hist |> ms

let max_latency hist outliers =
  float_of_int (max (H.max hist) outliers.max) |> ms

let outlier_mean_ms outliers =
  if outliers.count = 0 then 0.
  else float_of_int outliers.total /. float_of_int outliers.count |> ms

(* Record [latency] into [hist], or, if it is too large for the histogram,
   fold it into [outliers]. A non-positive latency is normally never expected. *)
let record_latency hist outliers latency =
  if latency < 0 then invalid_arg "Negative latency";
  if not (H.record_value hist latency) then (
    outliers.count <- outliers.count + 1;
    outliers.total <- outliers.total + latency;
    if latency > outliers.max then outliers.max <- latency)

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

let print_latency_only json output hist outliers =
  let mean_latency = mean_latency hist in
  let max_latency = max_latency hist outliers in
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
  let hist = make_hist () in
  let outliers = make_outliers () in
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
        record_latency hist outliers latency
    | _ -> ()
  in
  let init = Fun.id in
  let cleanup () = print_latency_only json output hist outliers in
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
