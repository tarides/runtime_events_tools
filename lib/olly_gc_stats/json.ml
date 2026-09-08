let number_format = format_of_string "%f"

let print oc jsont t =
  let wr = Bytesrw.Bytes.Writer.of_out_channel oc in
  match
    Jsont_bytesrw.encode ~format:Jsont.Indent ~number_format ~eod:true jsont t
      wr
  with
  | Ok () -> ()
  | Error str -> failwith ("JSON encoding failed: " ^ str)

let assoc_map_jsont ?kind ?doc t =
  let enc f mems acc =
    List.fold_left (fun acc (n, v) -> f Jsont.Meta.none n v acc) acc mems
  in
  Jsont.Object.(
    map ?kind ?doc Fun.id
    |> keep_unknown (Mems.map t ~enc:Jsont.Object.Mems.{ enc }) ~enc:Fun.id
    |> finish)

type float0 = float
(** a [float] that is truncated to an integer when emitting as JSON.

    This is useful for the GC stats that are only floats to avoid `int`
    overflows on 32-bit platforms. *)

let float0_jsont =
  let dec _ v = v in
  Jsont.(Base.number @@ Base.map ~kind:"%.0f" ~dec ~enc:Float.trunc ())

type 'a assoc_map = (string * 'a) list
(** a [["key1", value1; ...; "keyN", valueN]] list that is emitted as
    [{"key1": value1; ...; "keyN": valueN}].

    A String_map could've been used either, but that has no control over the
    order in which keys are emitted. *)

type ms = float
(** milliseconds *)

let ms_jsont = Jsont.number

type s = float
(** seconds *)

let s_jsont = Jsont.number

type percentage = float
(** [[0, 100]] *)

let percentage_jsont = Jsont.number

module Latency = struct
  type t = { mean_latency : ms; max_latency : ms; distr_latency : ms assoc_map }
  [@@deriving_inline jsont]

  let _ = fun (_ : t) -> ()

  let jsont =
    let make mean_latency max_latency distr_latency =
      { mean_latency; max_latency; distr_latency }
    in
    Jsont.Object.map ~kind:"T" make
    |> Jsont.Object.mem "mean_latency" ms_jsont ~enc:(fun t -> t.mean_latency)
    |> Jsont.Object.mem "max_latency" ms_jsont ~enc:(fun t -> t.max_latency)
    |> Jsont.Object.mem "distr_latency" (assoc_map_jsont ms_jsont)
         ~enc:(fun t -> t.distr_latency)
    |> Jsont.Object.finish

  let _ = jsont

  [@@@deriving.end]
end

module Gc_stats = struct
  type domain_stat = { wall_time : s; gc_time : s; gc_overhead : percentage }
  [@@deriving_inline jsont]

  let _ = fun (_ : domain_stat) -> ()

  let domain_stat_jsont =
    let make wall_time gc_time gc_overhead =
      { wall_time; gc_time; gc_overhead }
    in
    Jsont.Object.map ~kind:"Domain_stat" make
    |> Jsont.Object.mem "wall_time" s_jsont ~enc:(fun t -> t.wall_time)
    |> Jsont.Object.mem "gc_time" s_jsont ~enc:(fun t -> t.gc_time)
    |> Jsont.Object.mem "gc_overhead" percentage_jsont ~enc:(fun t ->
        t.gc_overhead)
    |> Jsont.Object.finish

  let _ = domain_stat_jsont

  [@@@deriving.end]

  type outliers = { count : int; mean_latency : ms; max_latency : ms }
  [@@deriving_inline jsont]

  let _ = fun (_ : outliers) -> ()

  let outliers_jsont =
    let make count mean_latency max_latency =
      { count; mean_latency; max_latency }
    in
    Jsont.Object.map ~kind:"Outliers" make
    |> Jsont.Object.mem "count" Jsont.int ~enc:(fun t -> t.count)
    |> Jsont.Object.mem "mean_latency" ms_jsont ~enc:(fun t -> t.mean_latency)
    |> Jsont.Object.mem "max_latency" ms_jsont ~enc:(fun t -> t.max_latency)
    |> Jsont.Object.finish

  let _ = outliers_jsont

  [@@@deriving.end]

  type allocations = {
    total_heap : float0;
    minor_heap : float0;
    major_heap : float0 option; [@option]
    promoted_words : float0;
    promoted_pct : percentage;
  }
  [@@deriving_inline jsont]

  let _ = fun (_ : allocations) -> ()

  let allocations_jsont =
    let make total_heap minor_heap major_heap promoted_words promoted_pct =
      { total_heap; minor_heap; major_heap; promoted_words; promoted_pct }
    in
    Jsont.Object.map ~kind:"Allocations" make
    |> Jsont.Object.mem "total_heap" float0_jsont ~enc:(fun t -> t.total_heap)
    |> Jsont.Object.mem "minor_heap" float0_jsont ~enc:(fun t -> t.minor_heap)
    |> Jsont.Object.mem "major_heap"
         (Jsont.option float0_jsont)
         ~enc:(fun t -> t.major_heap)
         ~dec_absent:None ~enc_omit:Option.is_none
    |> Jsont.Object.mem "promoted_words" float0_jsont ~enc:(fun t ->
        t.promoted_words)
    |> Jsont.Object.mem "promoted_pct" percentage_jsont ~enc:(fun t ->
        t.promoted_pct)
    |> Jsont.Object.finish

  let _ = allocations_jsont

  [@@@deriving.end]

  type domain_alloc_stat = {
    total : int;
    minor : int;
    promoted : int;
    major : int;
    promoted_pct : percentage;
  }
  [@@deriving_inline jsont]

  let _ = fun (_ : domain_alloc_stat) -> ()

  let domain_alloc_stat_jsont =
    let make total minor promoted major promoted_pct =
      { total; minor; promoted; major; promoted_pct }
    in
    Jsont.Object.map ~kind:"Domain_alloc_stat" make
    |> Jsont.Object.mem "total" Jsont.int ~enc:(fun t -> t.total)
    |> Jsont.Object.mem "minor" Jsont.int ~enc:(fun t -> t.minor)
    |> Jsont.Object.mem "promoted" Jsont.int ~enc:(fun t -> t.promoted)
    |> Jsont.Object.mem "major" Jsont.int ~enc:(fun t -> t.major)
    |> Jsont.Object.mem "promoted_pct" percentage_jsont ~enc:(fun t ->
        t.promoted_pct)
    |> Jsont.Object.finish

  let _ = domain_alloc_stat_jsont

  [@@@deriving.end]

  type collections = {
    minor : int;
    major : int;
    forced_major : int;
    compactions : int;
  }
  [@@deriving_inline jsont]

  let _ = fun (_ : collections) -> ()

  let collections_jsont =
    let make minor major forced_major compactions =
      { minor; major; forced_major; compactions }
    in
    Jsont.Object.map ~kind:"Collections" make
    |> Jsont.Object.mem "minor" Jsont.int ~enc:(fun t -> t.minor)
    |> Jsont.Object.mem "major" Jsont.int ~enc:(fun t -> t.major)
    |> Jsont.Object.mem "forced_major" Jsont.int ~enc:(fun t -> t.forced_major)
    |> Jsont.Object.mem "compactions" Jsont.int ~enc:(fun t -> t.compactions)
    |> Jsont.Object.finish

  let _ = collections_jsont

  [@@@deriving.end]

  type t = {
    version : int;
    wall_time : s;
    cpu_time : s;
    gc_time : s;
    gc_overhead : percentage;
    max_rss_kb : int;
    domain_stats : domain_stat assoc_map;
    mean_latency : ms;
    stddev_latency : ms;
    min_latency : ms;
    max_latency : ms;
    distr_latency : ms assoc_map;
    outliers : outliers;
    allocations : allocations;
    domain_alloc_stats : domain_alloc_stat assoc_map option; [@option]
    collections : collections;
    stats_reliable : bool;
  }
  [@@deriving_inline jsont]

  let _ = fun (_ : t) -> ()

  let jsont =
    let make version wall_time cpu_time gc_time gc_overhead max_rss_kb
        domain_stats mean_latency stddev_latency min_latency max_latency
        distr_latency outliers allocations domain_alloc_stats collections
        stats_reliable =
      {
        version;
        wall_time;
        cpu_time;
        gc_time;
        gc_overhead;
        max_rss_kb;
        domain_stats;
        mean_latency;
        stddev_latency;
        min_latency;
        max_latency;
        distr_latency;
        outliers;
        allocations;
        domain_alloc_stats;
        collections;
        stats_reliable;
      }
    in
    Jsont.Object.map ~kind:"T" make
    |> Jsont.Object.mem "version" Jsont.int ~enc:(fun t -> t.version)
    |> Jsont.Object.mem "wall_time" s_jsont ~enc:(fun t -> t.wall_time)
    |> Jsont.Object.mem "cpu_time" s_jsont ~enc:(fun t -> t.cpu_time)
    |> Jsont.Object.mem "gc_time" s_jsont ~enc:(fun t -> t.gc_time)
    |> Jsont.Object.mem "gc_overhead" percentage_jsont ~enc:(fun t ->
        t.gc_overhead)
    |> Jsont.Object.mem "max_rss_kb" Jsont.int ~enc:(fun t -> t.max_rss_kb)
    |> Jsont.Object.mem "domain_stats" (assoc_map_jsont domain_stat_jsont)
         ~enc:(fun t -> t.domain_stats)
    |> Jsont.Object.mem "mean_latency" ms_jsont ~enc:(fun t -> t.mean_latency)
    |> Jsont.Object.mem "stddev_latency" ms_jsont ~enc:(fun t ->
        t.stddev_latency)
    |> Jsont.Object.mem "min_latency" ms_jsont ~enc:(fun t -> t.min_latency)
    |> Jsont.Object.mem "max_latency" ms_jsont ~enc:(fun t -> t.max_latency)
    |> Jsont.Object.mem "distr_latency" (assoc_map_jsont ms_jsont)
         ~enc:(fun t -> t.distr_latency)
    |> Jsont.Object.mem "outliers" outliers_jsont ~enc:(fun t -> t.outliers)
    |> Jsont.Object.mem "allocations" allocations_jsont ~enc:(fun t ->
        t.allocations)
    |> Jsont.Object.mem "domain_alloc_stats"
         (Jsont.option (assoc_map_jsont domain_alloc_stat_jsont))
         ~enc:(fun t -> t.domain_alloc_stats)
         ~dec_absent:None ~enc_omit:Option.is_none
    |> Jsont.Object.mem "collections" collections_jsont ~enc:(fun t ->
        t.collections)
    |> Jsont.Object.mem "stats_reliable" Jsont.bool ~enc:(fun t ->
        t.stats_reliable)
    |> Jsont.Object.finish

  let _ = jsont

  [@@@deriving.end]
end
