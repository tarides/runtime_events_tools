type t = {
  stop_flag : bool Atomic.t;
  domain : unit Domain.t;
  alive : bool Atomic.t;
  peak_rss : int Atomic.t;
}

let poller : t option Atomic.t = Atomic.make None

(* [sleep_at_least stop_flag interval] sleeps for [interval] seconds, in subdivisions 
    of [stop_check_interval] seconds. For each [stop_check_interval], [stop_flag] is 
    consulted, and if true, an early return is triggered. *)
let stop_check_interval = 0.05

let sleep_at_least stop_flag interval =
  let deadline = Unix.gettimeofday () +. interval in
  let rec sleep_until_deadline () =
    let remaining = deadline -. Unix.gettimeofday () in
    if remaining > 0.0 && not (Atomic.get stop_flag) then (
      (try Unix.sleepf (Float.min remaining stop_check_interval)
       with Unix.Unix_error (Unix.EINTR, _, _) -> ());
      sleep_until_deadline ())
  in
  sleep_until_deadline ()

(* Waking the domain immediately could be done with a self-pipe, and on Windows 
  that has to be a [socketpair], since [select] there accepts none but sockets. OCaml
  emulates [socketpair] on Windows via an AF_UNIX socket at a path from GetTempFileName 
  and then deleted. Therefore, two olly processes sharing the temp directory can race 
  for the same path. That path must also fit in sun_path, 108 bytes, which is too low
  for many systems. This is why [sleep_at_least] is used instead. *)
let start ~alive_check ~pid ~interval ~sample_rss =
  if Option.is_some (Atomic.get poller) then
    failwith "Process poller already started";
  if interval <= 0.0 then invalid_arg "interval must be positive";
  let stop_flag = Atomic.make false in
  let alive = Atomic.make true in
  let peak_rss = Atomic.make 0 in
  let rec start_loop () =
    if not @@ Atomic.get stop_flag then (
      let still_alive = alive_check () in
      Atomic.set alive still_alive;
      if still_alive then (
        if sample_rss then
          Atomic.set peak_rss
            (max (Platform.get_rss_kb ~pid) (Atomic.get peak_rss));
        (* wait for [interval], or until signalled to stop *)
        sleep_at_least stop_flag interval;
        start_loop ()))
  in
  let domain =
    Domain.spawn (fun () ->
        Fun.protect ~finally:(fun () -> Atomic.set alive false) start_loop)
  in
  Atomic.set poller (Some { stop_flag; domain; alive; peak_rss })

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
  | Some { stop_flag; domain; _ } ->
      Atomic.set stop_flag true;
      Domain.join domain
