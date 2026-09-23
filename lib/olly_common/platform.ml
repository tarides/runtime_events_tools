type handle = int

external olly_is_process_alive : int -> bool = "olly_is_process_alive"

let is_process_alive ~pid = olly_is_process_alive pid

external pid_of_handle : handle -> int = "olly_pid_of_handle"

(* The child inherits our own standard descriptors. Not [Unix.stdin],
   [Unix.stdout] and [Unix.stderr], which are snapshots: on Windows they cache
   the [HANDLE] that file descriptors 0, 1 and 2 had when the Unix module was
   initialised, and never look it up again. Anything that redirects the
   underlying C runtime descriptor closes that handle and leaves those values
   dangling: alcotest captures each test's output with a C-level [dup2] over
   descriptors 1 and 2. [create_process] then fails with [EBADF]. Going
   through the standard channels looks the handle up afresh on every call, and
   is the identity on Unix. *)
let create_process_env executable args env =
  Unix.create_process_env executable args env
    (Unix.descr_of_in_channel Stdlib.stdin)
    (Unix.descr_of_out_channel Stdlib.stdout)
    (Unix.descr_of_out_channel Stdlib.stderr)

let waitpid flags handle =
  match Unix.waitpid flags handle with 0, _ -> None | _, status -> Some status

let terminate h = try Unix.kill h Sys.sigkill with Unix.Unix_error _ -> ()

(* How long to wait for a child to die after we have terminated it. Bounded
   because [waitpid []] on a process that refuses to die never returns, and
   so that a caller can run as a [Fun.protect] finalizer, where hanging there
   would strand olly at exit. *)
let terminate_wait_timeout = 2.0
let terminate_wait_interval = 0.005

let terminate_and_reap handle =
  terminate handle;
  let deadline = Unix.gettimeofday () +. terminate_wait_timeout in
  let rec wait () =
    match waitpid [ Unix.WNOHANG ] handle with
    | Some _ -> true
    | None -> retry ()
    (* Nothing left to reap: already gone, or never ours. *)
    | exception Unix.Unix_error ((Unix.ECHILD | Unix.EBADF), _, _) -> true
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> retry ()
  and retry () =
    Unix.gettimeofday () < deadline
    &&
    ((try Unix.sleepf terminate_wait_interval
      with Unix.Unix_error (Unix.EINTR, _, _) -> ());
     wait ())
  in
  wait ()

external olly_get_rss_kb : int -> int = "olly_get_rss_kb"

let get_rss_kb ~pid = olly_get_rss_kb pid
