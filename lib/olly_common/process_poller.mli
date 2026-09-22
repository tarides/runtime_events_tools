(** Sample a process's status and peak resident set size from a dedicated
    domain. *)

val start :
  alive_check:(unit -> bool) ->
  pid:int ->
  ring_file:string ->
  interval:float ->
  sample_rss:bool ->
  unit
(** [start ~alive_check ~pid ~ring_file ~interval ~sample_rss] spawns a domain
    which, every [interval] seconds,
    - samples [alive_check ()],
    - if the process is alive and [sample_rss] is true, it samples its RSS,
      tracking the peak.

    [ring_file] is the path to the process's runtime events ring buffer. The
    ring is mapped into the traced process, so its resident pages count towards
    that process's RSS; where the platform allows it they are attributed to the
    ring and excluded from the tracked peak (see [peak_rss_excludes_ring]).
    Passing [""] asks for the RSS as the kernel reports it.

    [interval] must be positive. [start] can only be used once per process
    lifetime. *)

val is_alive : unit -> bool
(** retrieve last process status sampled *)

val peak_rss : unit -> int
(** returns the peak RSS observed so far, in kB.*)

val peak_rss_excludes_ring : unit -> bool
(** whether every RSS sample taken so far had the resident pages of the runtime
    events ring buffer excluded from it. False means [peak_rss] includes the
    ring, and so overestimates the program's own memory footprint — by the size
    of the ring, which is typically much larger than the program's live memory.
    Only meaningful if [start] was passed [~sample_rss:true] and a non-empty
    [~ring_file]. *)

val stop : unit -> unit
(** signals the poller to stop and waits for it to finish *)
