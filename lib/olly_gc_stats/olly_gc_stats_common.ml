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
let highest_trackable_value = 1 lsl 34

(* Mutable stats *)
let wall_time = { start_time = 0.; end_time = 0. }
let domain_elapsed_times = Array.make number_domains 0.
let domain_gc_times = Array.make number_domains 0
let domain_minor_words = Array.make number_domains 0
let domain_promoted_words = Array.make number_domains 0
let minor_collections = ref 0
let major_collections = ref 0
let forced_major_collections = ref 0
let compactions = ref 0

(* conversions *)
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
    let distr_latency =
      percentiles |> Array.to_seq
      |> Seq.map (fun percentile ->
          let value =
            H.value_at_percentile hist percentile |> float_of_int |> ms
          in
          (Printf.sprintf "%.4f" percentile, value))
      |> List.of_seq
    in
    Json.Latency.{ mean_latency; max_latency; distr_latency }
    |> Json.print oc Json.Latency.jsont
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
  let on_success () = print_latency_only json output hist outliers in
  let open Olly_common.Launch in
  try
    `Ok
      (olly
         {
           empty_config with
           runtime_begin;
           runtime_end;
           on_success;
           sample_rss = false;
           poll_sleep;
           runtime_events_dir;
         }
         exec_args)
  with Fail msg -> `Error (false, msg)

let ( &&& ) a b =
  match (a, b) with
  | Ok (), Ok () -> Ok ()
  | (Error _ as e), Ok () | Ok (), (Error _ as e) -> e
  | Error e1, Error e2 -> Error (e1 @ e2)

let ( ||| ) a b =
  match (a, b) with
  | Ok (), _ | _, Ok () -> Ok ()
  | Error e1, Error e2 -> Error (e1 @ e2)

let check_eq field pp ~expected actual =
  if expected <> actual then
    Error [ Format.asprintf "%s: %a <> %a" field pp actual pp expected ]
  else Ok ()

let check_range field pp ~lo ~hi actual =
  if actual < lo || actual > hi then
    Error [ Format.asprintf "%s: %a ∉ [%a, %a]" field pp actual pp lo pp hi ]
  else Ok ()

let pp_s ppf s = Format.fprintf ppf "%f s" s

let validate_domain_stat (t : Json.Gc_stats.t)
    (key, (ds : Json.Gc_stats.domain_stat)) =
  if key |> int_of_string_opt |> Option.is_none then
    Error [ Printf.sprintf "Domain stat map key not an integer: %s" key ]
  else
    Ok ()
    &&& check_range "0 <= gc_time <= wall_time" pp_s ~lo:0. ~hi:ds.wall_time
          ds.gc_time
    &&& check_range "0 <= gc_time <= global.gc_time" pp_s ~lo:0. ~hi:t.gc_time
          ds.gc_time
    &&& check_range "0 <= wall_time <= global.wall_time" pp_s ~lo:0.
          ~hi:t.wall_time ds.wall_time
    &&& check_range "0 <= gc_overhead <= 100" pp_s ~lo:0. ~hi:100. t.gc_overhead

let validate_distr_latency (t : Json.Gc_stats.t) (key, (latency : float)) =
  if key |> int_of_string_opt |> Option.is_none then
    Error [ Printf.sprintf "Latency map key not an integer: %s" key ]
  else
    Ok ()
    &&& check_range "min_latency <= latency <= max_latency" pp_s
          ~lo:t.min_latency ~hi:t.max_latency latency

let validate_outliers (t : Json.Gc_stats.t) (outliers : Json.Gc_stats.outliers)
    =
  check_range "0 <= outliers" Format.pp_print_int ~lo:0 ~hi:Int.max_int
    outliers.count
  &&& check_range "0 <= mean_latency <= max_latency" Format.pp_print_float
        ~lo:0. ~hi:outliers.max_latency outliers.mean_latency
  &&& check_range "t.min_latency <= mean_latency <= t.max_latency"
        Format.pp_print_float ~lo:t.min_latency ~hi:t.max_latency
        outliers.mean_latency
  &&& check_range "t.min_latency <= max_latency <= t.max_latency"
        Format.pp_print_float ~lo:t.min_latency ~hi:t.max_latency
        outliers.max_latency

let validate_domain_alloc_stat (t : Json.Gc_stats.t)
    (key, (da : Json.Gc_stats.domain_alloc_stat)) =
  if key |> int_of_string_opt |> Option.is_none then
    Error [ Printf.sprintf "Domain alloc stat map key not an integer: %s" key ]
  else
    Ok ()
    &&& check_eq "total = minor - promoted + major" Format.pp_print_int
          ~expected:(da.minor - da.promoted + da.major)
          da.total
    &&& check_range "0 <= promoted_pct <= 100" Format.pp_print_float ~lo:0.
          ~hi:100. da.promoted_pct
    &&& check_range "total <= t.total_heap" Format.pp_print_int ~lo:0
          ~hi:(Float.to_int t.allocations.total_heap)
          da.total
    &&& check_range "minor <= t.minor_heap" Format.pp_print_int ~lo:0
          ~hi:(Float.to_int t.allocations.minor_heap)
          da.minor
    &&& check_range "promoted <= t.promoted_words" Format.pp_print_int ~lo:0
          ~hi:(Float.to_int t.allocations.promoted_words)
          da.promoted
    &&& check_range "major <= t.major_heap" Format.pp_print_int ~lo:0
          ~hi:
            (t.allocations.major_heap |> Option.value ~default:0.
           |> Float.to_int)
          da.major

let validate_assoc_map t f map =
  List.fold_left (fun acc e -> acc &&& f t e) (Ok ()) map

let validate_opt t f = function None -> Ok () | Some x -> f t x

let validate_domain_alloc_stats t opt =
  let is_53_plus =
    Sys.ocaml_release.major > 5 || Sys.ocaml_release.minor >= 3
  in
  match (opt, is_53_plus) with
  | None, true -> Error [ "Missing domain_alloc_stats" ]
  | None, false -> Ok ()
  | Some stats, _ -> validate_assoc_map t validate_domain_alloc_stat stats

let current_version = 2

let validate_json (t : Json.Gc_stats.t) =
  let domains = List.length t.domain_stats in
  check_range "1 <= version <= 2" Format.pp_print_int ~lo:1 ~hi:current_version
    t.version
  &&& check_range "0 <= cpu_time <= wall_time*domains" pp_s ~lo:0.
        ~hi:(t.wall_time *. float_of_int domains)
        t.cpu_time
  &&& check_range "0 <= gc_time <= cpu_time" pp_s ~lo:0. ~hi:t.cpu_time
        t.gc_time
  &&& check_range "0 <= gc_overhead <= 100" Format.pp_print_float ~lo:0.
        ~hi:100. t.gc_overhead
  (* x86-64 and RISC-V 5-level paging: 57 bits,
      anything larger is likely a bug *)
  &&& check_range "1 <= max_rss_kb" Format.pp_print_int ~lo:0
        ~hi:((1 lsl 57) - 1)
        t.max_rss_kb
  &&& validate_assoc_map t validate_domain_stat t.domain_stats
  &&& check_range "min_latency <= mean_latency <= max_latency"
        Format.pp_print_float ~lo:t.min_latency ~hi:t.max_latency t.mean_latency
  &&& validate_outliers t t.outliers
  &&& validate_domain_alloc_stats t t.domain_alloc_stats
  &&& check_eq "total_heap = minor - promoted + major" Format.pp_print_int
        ~expected:
          (t.allocations.minor_heap -. t.allocations.promoted_words
           +. Option.value ~default:0. t.allocations.major_heap
          |> Float.to_int)
        (Float.to_int t.allocations.total_heap)
  &&& check_range "0 <= promoted_words <= minor_heap" Format.pp_print_float
        ~lo:0. ~hi:t.allocations.minor_heap t.allocations.promoted_words
  &&& check_range "0 <= promoted_pct <= 100" Format.pp_print_float ~lo:0.
        ~hi:100. t.allocations.promoted_pct
  &&& check_range "0 <= collections.minor" Format.pp_print_int ~lo:0
        ~hi:Int.max_int t.collections.minor
  &&& check_range "0 <= collections.major" Format.pp_print_int ~lo:0
        ~hi:Int.max_int t.collections.major
  &&& check_range "0 <= collections.forced_major" Format.pp_print_int ~lo:0
        ~hi:Int.max_int t.collections.forced_major
  &&& check_range "0 <= collections.compactions" Format.pp_print_int ~lo:0
        ~hi:Int.max_int t.collections.compactions

let singleton x = [ x ]

let validate_gc_stats jsonlines files =
  let pp_list =
    Format.pp_print_list ~pp_sep:Format.pp_print_space Format.pp_print_string
  in
  let res =
    files
    |> List.map @@ fun file ->
       In_channel.with_open_bin file @@ fun ch ->
       let res =
         if jsonlines then
           In_channel.fold_lines
             (fun (n, acc) line ->
               let res =
                 line
                 |> Jsont_bytesrw.decode_string ~file Json.Gc_stats.jsont
                 |> Result.map_error singleton
               in
               let res = Result.bind res validate_json in
               let res =
                 if Result.is_error res then
                   let ver =
                     line
                     |> Jsont_bytesrw.decode_string ~file
                          Json.Gc_stats.version_only_jsont
                     |> Result.map_error singleton
                   in
                   match ver with
                   | Error _ as e -> e
                   | Ok v ->
                       if v.version != current_version then
                         (* skip different versions *)
                         Ok ()
                       else
                         (* version matched, keep the previous error *)
                         res
                 else res
               in
               (n + 1, acc &&& res))
             (1, Ok ()) ch
           |> snd
         else
           let reader = Bytesrw.Bytes.Reader.of_in_channel ch in
           let res =
             Jsont_bytesrw.decode ~locs:true ~file Json.Gc_stats.jsont reader
             |> Result.map_error singleton
           in
           Result.bind res validate_json
       in
       Result.fold ~ok:(fun _ -> [ "OK" ]) ~error:Fun.id res
       |> Format.printf "@[<v1>%s: %a@]@." file pp_list;
       res
  in
  if not (List.for_all Result.is_ok res) then exit Cmdliner.Cmd.Exit.some_error
