external get_rss_kb : int -> int = "olly_get_rss_kb"

type t = { stop_flag : bool Atomic.t; domain : int Domain.t }

let rss_poller : t option ref = ref None

let start ~pid ~interval =
  if Option.is_some !rss_poller then failwith "RSS Poller already started";
  if interval <= 0.0 then invalid_arg "interval must be positive";
  let stop_flag = Atomic.make false in
  let domain =
    Domain.spawn (fun () ->
        let rec loop peak =
          if Atomic.get stop_flag then peak
          else begin
            (* sample before waiting so that we get a reading at launch *)
            let rss = get_rss_kb pid in
            (try Unix.sleepf interval
             with Unix.Unix_error (Unix.EINTR, _, _) -> ());
            loop (max rss peak)
          end
        in
        loop 0)
  in
  rss_poller := Some { stop_flag; domain }

let stop () =
  match !rss_poller with
  | None -> failwith "RSS Poller not running"
  | Some t ->
      Atomic.set t.stop_flag true;
      Domain.join t.domain
