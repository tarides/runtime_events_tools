type handle
(** A process we spawned: a Win32 [HANDLE] on Windows, a pid elsewhere. Produced
    by [create_process_env], consumed by [waitpid] and [terminate_and_reap]. *)

val pid_of_handle : handle -> int
(** The real OS pid, which is what the child names its ring file after. Raises
    [Unix_error] if the handle is invalid or not queryable. *)

val is_process_alive : pid:int -> bool
(** For a process we did not spawn, and so have no handle for. *)

val create_process_env : string -> string array -> string array -> handle
(** [create_process_env executable args env] spawns [executable] with our own
    standard input, output and error. Those are looked up afresh here rather
    than taken from [Unix.stdin] and friends, which on Windows cache the handle
    descriptors 0, 1 and 2 had at startup and so go stale as soon as anything
    redirects them at the C runtime level, as alcotest's per-test output capture
    does. *)

val waitpid : Unix.wait_flag list -> handle -> Unix.process_status option
(** [None] means still running, and only arises under [WNOHANG]. On [Some] the
    handle has been closed and must not be used again. *)

val terminate_and_reap : handle -> bool
(** Terminate [handle] and reap it. Returns whether it is actually gone within a
    given time bound: on Windows [TerminateProcess] can fail, and until the
    child dies it keeps the ring file mapped. *)

val get_rss_kb : pid:int -> int
(** Peak resident set size; 0 where unsupported, which includes Windows. *)
