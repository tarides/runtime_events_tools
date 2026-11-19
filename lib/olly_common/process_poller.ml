(* Sample the RSS of [pid], excluding the resident pages of its
   runtime_events ring buffer [ring_file], and fold it into [peak_rss].

   The ring is mapped into the traced process, so its resident pages —
   routinely two orders of magnitude more than the program's own live
   memory — are charged to the process's RSS.  Where the platform can
   attribute them to the ring we subtract them; where it cannot,
   [rss_and_ring_kb] reports -1 and we record that the peak still
   includes the ring rather than silently reporting an inflated
   footprint. *)
let sample_peak_rss ~pid ~ring_file ~peak_rss ~excludes_ring ~hwm =
  let rss_kb, ring_kb, hwm_kb = Platform.get_rss_and_ring_kb ~pid ~ring_file in
  (* A live process always has a non-zero RSS, so zero/negative means we could not read
     one, possibly because the process exited between the liveness check and here.  
     That is not a sample in which the ring went unattributed, and must not be recorded 
     as one: [excludes_ring] never goes back to true, so a single such sample at the end 
     of an otherwise sound run would report the whole peak as untrustworthy. *)
  let ring_kb =
    if ring_kb < 0 then (
      Atomic.set excludes_ring false;
      0)
    else ring_kb
  in
  let remove_ring rss =
    if rss > 0 then
      (* On Linux and Windows the ring's pages are counted from the traced
           process's own page tables, the same ones its RSS is drawn from, so
           there they cannot exceed it. On macOS and FreeBSD the count comes
           from the backing object, which olly has mapped too, so it can
           include pages the traced process never faulted in; clamp rather
           than report a negative footprint. *)
      max 0 (rss - ring_kb)
    else rss
  in
  let rss_kb = remove_ring rss_kb in
  let hwm_kb = remove_ring hwm_kb in
  Atomic.set peak_rss (max rss_kb (Atomic.get peak_rss));
  Atomic.set hwm (max hwm_kb (Atomic.get hwm))

type t = {
  stop_flag : bool Atomic.t;
  domain : unit Domain.t;
  alive : bool Atomic.t;
  peak_rss : int Atomic.t;
  hwm : int Atomic.t;
  excludes_ring : bool Atomic.t;
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
let start ~alive_check ~pid ~ring_file ~interval ~sample_rss =
  if Option.is_some (Atomic.get poller) then
    failwith "Process poller already started";
  if interval <= 0.0 then invalid_arg "interval must be positive";
  let stop_flag = Atomic.make false in
  let alive = Atomic.make true in
  let peak_rss = Atomic.make 0 in
  let hwm = Atomic.make (-1) in
  let excludes_ring = Atomic.make true in
  let rec start_loop () =
    if not @@ Atomic.get stop_flag then (
      let still_alive = alive_check () in
      Atomic.set alive still_alive;
      if still_alive then (
        if sample_rss then
          sample_peak_rss ~pid ~ring_file ~peak_rss ~hwm ~excludes_ring;
        sleep_at_least stop_flag interval;
        start_loop ()))
  in
  let domain =
    Domain.spawn (fun () ->
        Fun.protect ~finally:(fun () -> Atomic.set alive false) start_loop)
  in
  Atomic.set poller
    (Some { stop_flag; domain; alive; peak_rss; excludes_ring; hwm })

let get_poller () =
  match Atomic.get poller with
  | None -> failwith "Process poller not started"
  | Some t -> t

let is_alive () =
  let t = get_poller () in
  Atomic.get t.alive

let peak_rss () =
  let t = get_poller () in
  Atomic.get t.peak_rss

let peak_rss_excludes_ring () =
  let t = get_poller () in
  Atomic.get t.excludes_ring

let high_watermark_rss () =
  let t = get_poller () in
  Atomic.get t.hwm

let stop () =
  let { stop_flag; domain; _ } = get_poller () in
  Atomic.set stop_flag true;
  Domain.join domain
