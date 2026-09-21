type handle = int

external olly_is_process_alive : int -> bool = "olly_is_process_alive"

let is_process_alive ~pid = olly_is_process_alive pid

external pid_of_handle : handle -> int = "olly_pid_of_handle"

let create_process_env = Unix.create_process_env

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
