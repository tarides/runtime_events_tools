type handle
(** A process we spawned: a Win32 [HANDLE] on Windows, a pid elsewhere. Produced
    by [create_process_env], consumed by [waitpid] and [terminate_and_reap]. *)

val pid_of_handle : handle -> int
(** The real OS pid, which is what the child names its ring file after. Raises
    [Unix_error] if the handle is invalid or not queryable. *)

val is_process_alive : pid:int -> bool
(** For a process we did not spawn, and so have no handle for. *)

val create_process_env :
  string ->
  string array ->
  string array ->
  Unix.file_descr ->
  Unix.file_descr ->
  Unix.file_descr ->
  handle

val waitpid : Unix.wait_flag list -> handle -> Unix.process_status option
(** [None] means still running, and only arises under [WNOHANG]. On [Some] the
    handle has been closed and must not be used again. *)

val terminate_and_reap : handle -> bool
(** Terminate [handle] and reap it. Returns whether it is actually gone within a
    given time bound: on Windows [TerminateProcess] can fail, and until the
    child dies it keeps the ring file mapped. *)

val get_rss_and_ring_kb : pid:int -> ring_file:string -> int * int
(** Peak resident set size (0 where unsupported) and resident size of the ring
    file (-1 where unsupported). *)
