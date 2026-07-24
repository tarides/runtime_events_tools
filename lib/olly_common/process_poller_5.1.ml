external get_rss_kb : int -> int = "olly_get_rss_kb"

(* [stop_rd]/[stop_wr] form a self-pipe, used for early termination of the 
   [select] in the polling domain. *)
type t = {
  stop_rd : Unix.file_descr;
  stop_wr : Unix.file_descr;
  domain : unit Domain.t;
  alive : bool Atomic.t;
  peak_rss : int Atomic.t;
}

let poller : t option Atomic.t = Atomic.make None

(** sleeps at least [interval] seconds, or until one of [read_fds] is ready for
    reading. returns [false] iff it returns because of the latter condition and
    [true] otherwise. *)
let rec sleep_until_write read_fds interval =
  if interval > 0.0 then
    let start_time = Unix.gettimeofday () in
    try
      let ready_fds, _, _ = Unix.select read_fds [] [] interval in
      List.is_empty ready_fds
    with Unix.Unix_error (EINTR, _, _) ->
      let elapsed = Unix.gettimeofday () -. start_time in
      sleep_until_write read_fds (interval -. elapsed)
  else true

let start ~alive_check ~pid ~interval ~sample_rss =
  if Option.is_some (Atomic.get poller) then
    failwith "Process poller already started";
  if interval <= 0.0 then invalid_arg "interval must be positive";
  (* [socketpair] used for Windows compatibility *)
  let stop_rd, stop_wr =
    Unix.socketpair ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0
  in
  let alive = Atomic.make true in
  let peak_rss = Atomic.make 0 in
  let domain =
    Domain.spawn (fun () ->
        let read_fds = [ stop_rd ] in
        let rec loop () =
          let still_alive = alive_check () in
          Atomic.set alive still_alive;
          if still_alive then (
            if sample_rss then
              Atomic.set peak_rss (max (get_rss_kb pid) (Atomic.get peak_rss));
            (* wait for [interval], or until signalled to stop *)
            if sleep_until_write read_fds interval then loop ())
        in
        loop ())
  in
  Atomic.set poller (Some { stop_rd; stop_wr; domain; alive; peak_rss })

let is_alive () =
  match Atomic.get poller with
  | None -> failwith "Process poller not started"
  | Some t -> Atomic.get t.alive

let peak_rss () =
  match Atomic.get poller with
  | None -> failwith "Process poller not started"
  | Some t -> Atomic.get t.peak_rss

let stop () =
  match Atomic.get poller with
  | None -> failwith "Process poller not running"
  | Some { stop_wr; stop_rd; domain; _ } ->
      (* wake up [domain] *)
      ignore (Unix.write stop_wr (Bytes.make 1 '\000') 0 1 : int);
      Domain.join domain;
      Unix.close stop_wr;
      Unix.close stop_rd;
      ()
