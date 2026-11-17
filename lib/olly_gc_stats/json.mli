val print : out_channel -> 'a Jsont.t -> 'a -> unit
(** [print out jsont v] formats [v] as json using [jsont], and writes it to the
    [out]put channel.

    @raise Failure if encoding fails *)

type float0 = float
(** [float0] are floating point numbers that are truncated when emitted. They
    were originally integers, but tracked as float by the {!val:Gc} module to
    avoid overflow on 32-bit systems. *)

type 'a assoc_map = (string * 'a) list
(** A [{key: value; ...}] JSON object. The order of elements in a JSON object is
    implementation defined, to preserve the original order a list is used. *)

type ms = float
(** milliseconds *)

type s = float
(** seconds *)

type percentage = s
(** percentages between [[0%, 100%]] *)

module Latency : sig
  type t = { mean_latency : ms; max_latency : ms; distr_latency : ms assoc_map }
  (** GC latency, a minimal subset of {!type:Gc_stats.t} *)

  val jsont : t Jsont.t
  (** JSON encoding of {!type:t} *)
end

module Gc_stats : sig
  type domain_stat = { wall_time : s; gc_time : s; gc_overhead : percentage }
  (** per OCaml domain statistics *)

  type outliers = { count : int; mean_latency : ms; max_latency : ms }
  (** statistical outliers *)

  type heap_pools_stat = {
    words : int;  (** words used for small allocations in the major heap *)
    live_words : int;  (** live words in the small allocation pool *)
    frag_words : int;
        (** fragments in the small allocation pool due to size rounding *)
    wasted_words : int;
        (** words "wasted" in the small allocation pool: words - live_words -
            frag_words. Note that this doesn't include memory wasted by the C
            allocator for large allocations *)
  }

  type heap_live_stat = {
    major_pools : heap_pools_stat;
        (** small allocations pool in the major heap *)
    major_large_words : int;
        (** large words in the major heap (managed by the C heap, fragmentation
            unknown) *)
    heap_words : int;
        (** the OCaml heap size in words (doesn't include custom blocks) *)
    frag_wasted_percentage : percentage;
        (** 100 * major_pools.wasted_words / heap_words *)
  }
  (** OCaml heap current size *)

  type allocations = {
    total_heap : float0;
    minor_heap : float0;
    major_heap : float0 option;
    promoted_words : float0;
    promoted_pct : percentage;
    live : heap_live_stat option;
  }
  (** OCaml heap allocation statistics *)

  type domain_alloc_stat = {
    total : int;
    minor : int;
    promoted : int;
    major : int;
    promoted_pct : percentage;
  }
  (** Per domain allocation statistics *)

  type collections = {
    minor : int;
    major : int;
    forced_major : int;
    compactions : int;
  }
  (** Counts the number of GC cycles, whether initiated by the user or
      internally. *)

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
    domain_alloc_stats : domain_alloc_stat assoc_map option;
    collections : collections;
    event_words_lost : int;
    stats_reliable : bool;
  }
  (** Garbage collector statistics *)

  val jsont : t Jsont.t
  (** JSON encoding of {!type:t} *)

  type version_only = { version : int }
  (** Garbage collector statistics: version checking only *)

  val version_only_jsont : version_only Jsont.t
  (** JSON encoding of {!type:version_only} *)
end
