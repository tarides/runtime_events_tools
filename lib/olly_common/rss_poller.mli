(** Sample a process's peak resident set size from a dedicated domain. *)

val start : pid:int -> interval:float -> unit
(** [start ~pid ~interval] spawns a domain that samples the RSS of [pid] every
    [interval] seconds, tracking the peak. [interval] must be positive. *)

val stop : unit -> int
(** [stop t] signals the poller to stop, waits for it to finish, and returns the
    peak RSS observed, in kB. *)
