let lost_events ring_id num =
  Printf.eprintf "[ring_id=%d] Lost %d events\n%!" ring_id num

type subprocess = {
  alive : unit -> bool;
  cursor : Runtime_events.cursor;
  close : unit -> unit;
  pid : int;
}

type runtime_events_config = { log_wsize : int option; dir : string option }
type exec_config = Attach of string * int | Execute of string list

(* Raised by exec_process to indicate various unrecoverable failures. *)
exception Fail of string

(* On Windows, Unix.create_process_env returns a process HANDLE, not a PID.
   This C stub calls GetProcessId(handle) on Windows to get the real PID.
   On Unix it's the identity function since the handle IS the PID. *)
external get_process_id : int -> int = "olly_get_process_id"

let exec_process (config : runtime_events_config) (argsl : string list) :
    subprocess =
  if not (List.length argsl > 0) then
    raise (Fail (Printf.sprintf "no executable provided for exec_process"));

  let executable_filename = List.hd argsl in

  let dir =
    match config.dir with
    | None -> Filename.get_temp_dir_name () |> Unix.realpath
    | Some path -> Unix.realpath path
  in
  if not @@ Sys.file_exists dir then
    raise (Fail (Printf.sprintf "directory %s does not exist" dir));
  if not @@ Sys.is_directory dir then
    raise (Fail (Printf.sprintf "file %s is not a directory" dir));

  let env =
    Array.append
      [|
        (* See https://ocaml.org/manual/5.3/runtime-tracing.html#s:runtime-tracing-environment-variables *)
        "OCAML_RUNTIME_EVENTS_START=1";
        "OCAML_RUNTIME_EVENTS_DIR=" ^ dir;
        "OCAML_RUNTIME_EVENTS_PRESERVE=1";
        ((* See https://ocaml.org/manual/5.3/runtime.html#s:ocamlrun-options *)
         let log_wsize =
           match config.log_wsize with
           | Some i -> "e=" ^ Int.to_string i
           | None -> ""
         in
         "OCAMLRUNPARAM=" ^ log_wsize);
      |]
      (Unix.environment ())
  in
  let child_handle =
    try
      Unix.create_process_env executable_filename (Array.of_list argsl) env
        Unix.stdin Unix.stdout Unix.stderr
    with Unix.Unix_error (Unix.ENOENT, _, _) ->
      raise
        (Fail (Printf.sprintf "executable %s not found" executable_filename))
  in
  let child_pid = get_process_id child_handle in
  (* Poll until we can create a cursor for the child's ring buffer.
     The OCaml runtime creates the .events file then initializes it,
     so we retry create_cursor rather than just checking file existence.
     Under load (e.g. parallel dune builds) process creation can be slow. *)
  let timeout = 5.0 in
  let poll_interval = 0.05 in
  let deadline = Unix.gettimeofday () +. timeout in
  let cursor =
    let last_exn = ref None in
    let result = ref None in
    while !result = None && Unix.gettimeofday () < deadline do
      try result := Some (Runtime_events.create_cursor (Some (dir, child_pid)))
      with Failure _ as exn ->
        last_exn := Some exn;
        Unix.sleepf poll_interval
    done;
    match !result with
    | Some c -> c
    | None ->
        (* Clean up the child process before failing — otherwise it becomes
           an orphan. On Windows, orphan processes hold .events files open
           and prevent dune from cleaning up its temp directory. *)
        (try Unix.kill child_handle Sys.sigkill
         with Unix.Unix_error _ | Invalid_argument _ -> ());
        (try ignore (Unix.waitpid [] child_handle)
         with Unix.Unix_error _ -> ());
        let msg =
          match !last_exn with
          | Some (Failure str) -> str ^ " Directory: " ^ dir
          | _ -> "Timed out waiting for runtime events. Directory: " ^ dir
        in
        failwith msg
  in
  let alive () =
    match Unix.waitpid [ Unix.WNOHANG ] child_handle with
    | 0, _ -> true
    | p, _ when p = child_handle -> false
    | _, _ -> assert false
  and close () =
    Runtime_events.free_cursor cursor;
    (* We need to remove the ring buffers ourselves because we told
       the child process not to remove them *)
    let ring_file = Filename.concat dir (string_of_int child_pid ^ ".events") in
    try Unix.unlink ring_file with Unix.Unix_error _ -> ()
  in
  { alive; cursor; close; pid = child_handle }

let attach_process (dir : string) (pid : int) : subprocess =
  let cursor =
    try Runtime_events.create_cursor (Some (dir, pid))
    with Failure str ->
      (* Provide some context for which directory was passed to create_cursor *)
      failwith (str ^ " Directory: " ^ dir)
  in
  let alive () =
    try
      Unix.kill pid 0;
      true
    with Unix.Unix_error (Unix.ESRCH, _, _) -> false
  and close () = Runtime_events.free_cursor cursor in
  { alive; cursor; close; pid }

let launch_process config (exec_args : exec_config) : subprocess =
  match exec_args with
  | Execute argsl -> exec_process config argsl
  | Attach (dir, pid) -> attach_process dir pid

let collect_events poll_sleep child callbacks =
  (* Read from the child process *)
  while child.alive () do
    (try Runtime_events.read_poll child.cursor callbacks None |> ignore
     with Failure _ ->
       (* The child may have exited between the alive check and read_poll,
          leaving the ring buffer in a partially-written state. *)
       ());
    if poll_sleep > 0.0 then Unix.sleepf poll_sleep
  done;
  (* Do one more poll in case there are any remaining events we've missed.
     After the child exits, the ring buffer may be in an inconsistent state
     so we tolerate read failures here. *)
  try Runtime_events.read_poll child.cursor callbacks None |> ignore
  with Failure _ -> ()

type 'r acceptor_fn = int -> Runtime_events.Timestamp.t -> 'r

type consumer_config = {
  runtime_begin : (Runtime_events.runtime_phase -> unit) acceptor_fn;
  runtime_end : (Runtime_events.runtime_phase -> unit) acceptor_fn;
  runtime_counter : (Runtime_events.runtime_counter -> int -> unit) acceptor_fn;
  lifecycle : (Runtime_events.lifecycle -> int option -> unit) acceptor_fn;
  extra : Runtime_events.Callbacks.t -> Runtime_events.Callbacks.t;
  init : unit -> unit;
  cleanup : unit -> unit;
  poll_sleep : float;
  runtime_events_dir : string option;
  runtime_events_log_wsize : int option;
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
    poll_sleep = 0.1 (* Poll at 10Hz *);
    runtime_events_dir = None;
    (* Use default tmp directory *)
    runtime_events_log_wsize = None;
    (* Use default size 16. *)
  }

let olly config (exec_args : exec_config) =
  config.init ();
  Fun.protect ~finally:config.cleanup (fun () ->
      let runtime_config =
        {
          dir = config.runtime_events_dir;
          log_wsize = config.runtime_events_log_wsize;
        }
      in
      let child = launch_process runtime_config exec_args in
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
          collect_events config.poll_sleep child callbacks))
