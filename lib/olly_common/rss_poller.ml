external get_rss_kb : int -> int = "olly_get_rss_kb"

(* [stop_rd]/[stop_wr] form a self-pipe, used for early termination of the 
   [select] in the polling domain. *)
type t = {
  stop_rd : Unix.file_descr;
  stop_wr : Unix.file_descr;
  domain : int Domain.t;
}

let rss_poller : t option ref = ref None

let start ~pid ~interval =
  if Option.is_some !rss_poller then failwith "RSS Poller already started";
  if interval <= 0.0 then invalid_arg "interval must be positive";
  (* [socketpair] used for Windows compatibility *)
  let stop_rd, stop_wr = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  let domain =
    Domain.spawn (fun () ->
        let read_fds = [ stop_rd ] in
        let rec loop peak =
          let peak = max (get_rss_kb pid) peak in
          (* wait for [interval], or until signalled to stop *)
          let ready_fds, _, _ =
            try Unix.select read_fds [] [] interval
            with Unix.Unix_error (Unix.EINTR, _, _) -> ([], [], [])
          in
          if List.is_empty ready_fds then loop peak else peak
        in
        loop 0)
  in
  rss_poller := Some { stop_rd; stop_wr; domain }

let stop () =
  match !rss_poller with
  | None -> failwith "RSS Poller not running"
  | Some { stop_wr; stop_rd; domain } ->
      rss_poller := None;
      (* wake up [domain] *)
      ignore (Unix.write stop_wr (Bytes.make 1 '\000') 0 1 : int);
      let peak = Domain.join domain in
      Unix.close stop_wr;
      Unix.close stop_rd;
      peak
