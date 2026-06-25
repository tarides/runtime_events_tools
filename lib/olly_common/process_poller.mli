(** Sample a process's status and peak resident set size from a dedicated
    domain. *)

val start :
  alive_check:(unit -> bool) ->
  pid:int ->
  interval:float ->
  sample_rss:bool ->
  unit
(** [start ~alive_check ~pid ~interval ~sample_rss] spawns a domain which, every
    [interval] seconds,
    - samples [alive_check ()],
    - if the process is alive and [sample_rss] is true, it samples its RSS,
      tracking the peak.

    [interval] must be positive. [start] can only be used once per process
    lifetime. *)

val is_alive : unit -> bool
(** retrieve last process status sampled *)

val peak_rss : unit -> int
(** returns the peak RSS observed so far, in kB.*)

val stop : unit -> unit
(** signals the poller to stop and waits for it to finish *)
