let lost_events ring_id num =
  Printf.eprintf "[ring_id=%d] Lost %d events\n%!" ring_id num

type subprocess = {
  alive : unit -> bool;
  cursor : Runtime_events.cursor;
  close : unit -> unit;
}

type exec_config = Attach of string * int | Execute of string list

let exec_process argsl =
  let executable_filename = List.hd argsl in

  (* TODO Set the temp directory. We should make this configurable. *)
  let tmp_dir = Filename.get_temp_dir_name () |> Unix.realpath in
  let env =
    Array.append
      [|
        "OCAML_RUNTIME_EVENTS_START=1";
        "OCAML_RUNTIME_EVENTS_DIR=" ^ tmp_dir;
        "OCAML_RUNTIME_EVENTS_PRESERVE=1";
      |]
      (Unix.environment ())
  in
  let child_pid =
    Unix.create_process_env executable_filename (Array.of_list argsl) env
      Unix.stdin Unix.stdout Unix.stderr
  in
  Unix.sleepf 0.1;
  let cursor = Runtime_events.create_cursor (Some (tmp_dir, child_pid)) in
  let alive () =
    match Unix.waitpid [ Unix.WNOHANG ] child_pid with
    | 0, _ -> true
    | p, _ when p = child_pid -> false
    | _, _ -> assert false
  and close () =
    Runtime_events.free_cursor cursor;
    (* We need to remove the ring buffers ourselves because we told
       the child process not to remove them *)
    let ring_file =
      Filename.concat tmp_dir (string_of_int child_pid ^ ".events")
    in
    Unix.unlink ring_file
  in
  { alive; cursor; close }

let attach_process dir pid =
  let cursor = Runtime_events.create_cursor (Some (dir, pid)) in
  let alive () =
    try
      Unix.kill pid 0;
      true
    with Unix.Unix_error (Unix.ESRCH, _, _) -> false
  and close () = Runtime_events.free_cursor cursor in
  { alive; cursor; close }

let launch_process exec_args =
  match exec_args with
  | Execute argsl -> exec_process argsl
  | Attach (dir, pid) -> attach_process dir pid

let collect_events child callbacks =
  (* Read from the child process *)
  while child.alive () do
    Runtime_events.read_poll child.cursor callbacks None |> ignore;
    Unix.sleepf 0.1 (* Poll at 10Hz *)
  done;
  (* Do one more poll in case there are any remaining events we've missed *)
  Runtime_events.read_poll child.cursor callbacks None |> ignore

type 'r acceptor_fn = int -> Runtime_events.Timestamp.t -> 'r

type consumer_config = {
  runtime_begin : (Runtime_events.runtime_phase -> unit) acceptor_fn;
  runtime_end : (Runtime_events.runtime_phase -> unit) acceptor_fn;
  runtime_counter : (Runtime_events.runtime_counter -> int -> unit) acceptor_fn;
  lifecycle : (Runtime_events.lifecycle -> int option -> unit) acceptor_fn;
  extra : Runtime_events.Callbacks.t -> Runtime_events.Callbacks.t;
  init : unit -> unit;
  cleanup : unit -> unit;
}

let empty_config =
  {
    runtime_begin = (fun _ _ _ -> ());
    runtime_end = (fun _ _ _ -> ());
    runtime_counter = (fun _ _ _ _ -> ());
    lifecycle = (fun _ _ _ _ -> ());
    extra = Fun.id;
    init = (fun () -> ());
    cleanup = (fun () -> ());
  }

let olly config (exec_args : exec_config) =
  config.init ();
  Fun.protect ~finally:config.cleanup (fun () ->
      let child = launch_process exec_args in
      Fun.protect ~finally:child.close (fun () ->
          let callbacks =
            let {
              runtime_begin;
              runtime_end;
              runtime_counter;
              lifecycle;
              extra;
              _;
            } =
              config
            in
            Runtime_events.Callbacks.create ~runtime_begin ~runtime_end
              ~runtime_counter ~lifecycle ~lost_events ()
            |> extra
          in
          collect_events child callbacks))
