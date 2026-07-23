(* Native runtime_events consumer (see gc_counter_stubs.c).

   Owns a single cursor that processes every event type in C, bypassing the
   per-event OCaml callback dispatch that otherwise bottlenecks the consumer on
   bursty workloads. The OCaml side drives [poll] and reads the accumulated
   results out via the getters below at the end of the run. *)

(* [start dir pid] opens a cursor over [dir]/[pid].events and begins consuming
   events. Returns the runtime_events error code (0 = success). *)
external start : string -> int -> int = "olly_gc_counter_start"

(* [poll ()] drains all currently-available events; returns the number
   consumed. *)
external poll : unit -> int = "olly_gc_counter_poll"
external stop : unit -> unit = "olly_gc_counter_stop"

(* allocation counters (words), per domain *)
external minor_words : int -> int = "olly_gc_counter_minor_words" [@@noalloc]

external promoted_words : int -> int = "olly_gc_counter_promoted_words"
[@@noalloc]

external major_words : int -> int = "olly_gc_counter_major_words" [@@noalloc]

(* per-domain GC pause time (ns) and elapsed wall time (s) *)
external gc_time : int -> int = "olly_gc_counter_gc_time" [@@noalloc]
external domain_elapsed : int -> float = "olly_gc_counter_domain_elapsed"

(* wall clock bounds (s) *)
external wall_start : unit -> float = "olly_gc_counter_wall_start"
external wall_end : unit -> float = "olly_gc_counter_wall_end"

(* collection counts *)
external minor_collections : unit -> int = "olly_gc_counter_minor_collections"
[@@noalloc]

external major_collections : unit -> int = "olly_gc_counter_major_collections"
[@@noalloc]

external forced_major_collections : unit -> int
  = "olly_gc_counter_forced_major_collections"
[@@noalloc]

external compactions : unit -> int = "olly_gc_counter_compactions" [@@noalloc]

(* GC latency histogram (ns) *)
external hist_mean : unit -> float = "olly_gc_counter_hist_mean"
external hist_stddev : unit -> float = "olly_gc_counter_hist_stddev"
external hist_min : unit -> int = "olly_gc_counter_hist_min" [@@noalloc]
external hist_max : unit -> int = "olly_gc_counter_hist_max" [@@noalloc]

external hist_value_at_percentile : float -> int
  = "olly_gc_counter_hist_value_at_percentile"
[@@noalloc]

(* GC pauses beyond the histogram's range *)
external outliers_count : unit -> int = "olly_gc_counter_outliers_count"
[@@noalloc]

external outliers_total : unit -> int = "olly_gc_counter_outliers_total"
[@@noalloc]

external outliers_max : unit -> int = "olly_gc_counter_outliers_max" [@@noalloc]
external lost_events : unit -> int = "olly_gc_counter_lost_events" [@@noalloc]

(* diagnostics: per-ring events consumed and lost *)
external events : int -> int = "olly_gc_counter_events" [@@noalloc]

external lost_per_domain : int -> int = "olly_gc_counter_lost_per_domain"
[@@noalloc]
