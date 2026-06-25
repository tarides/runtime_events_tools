external get_rss_kb : int -> int = "olly_get_rss_kb"

type t = {
  stop_flag : bool Atomic.t;
  domain : unit Domain.t;
  alive : bool Atomic.t;
  peak_rss : int Atomic.t;
}

let poller : t option Atomic.t = Atomic.make None

let rec sleep_at_least stop_flag interval =
  if interval > 0.0 then
    let start_time = Unix.gettimeofday () in
    try Unix.sleepf interval
    with Unix.Unix_error (Unix.EINTR, _, _) ->
      if not @@ Atomic.get stop_flag then
        let elapsed = Unix.gettimeofday () -. start_time in
        sleep_at_least stop_flag (interval -. elapsed)

let start ~alive_check ~pid ~interval ~sample_rss =
  if Option.is_some (Atomic.get poller) then
    failwith "Process poller already started";
  if interval <= 0.0 then invalid_arg "interval must be positive";
  let stop_flag = Atomic.make false in
  let alive = Atomic.make true in
  let peak_rss = Atomic.make 0 in
  let domain =
    Domain.spawn (fun () ->
        let rec loop () =
          if not @@ Atomic.get stop_flag then (
            let still_alive = alive_check () in
            Atomic.set alive still_alive;
            if still_alive then (
              if sample_rss then
                Atomic.set peak_rss (max (get_rss_kb pid) (Atomic.get peak_rss));
              sleep_at_least stop_flag interval;
              loop ()))
        in
        loop ())
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
