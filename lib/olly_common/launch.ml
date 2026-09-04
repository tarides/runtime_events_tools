module Lost_events = struct
  let lost_words_count = ref 0

  let callback _ring_id num =
    let sum = !lost_words_count + num in
    (* detect overflow and stay at [max_int] *)
    lost_words_count := if sum < 0 then max_int else sum

  let were_events_lost () = !lost_words_count > 0

  let display () =
    if were_events_lost () then begin
      Printf.eprintf "Lost %d ring buffer words, stats not reliable%s\n%!"
        !lost_words_count
        (if !lost_words_count = max_int then
           " (possible counter overflow detected)\n%!"
         else "")
    end
end

(* Where the process we are tracing came from. The two cases genuinely differ:
   we own a child we launched and can wait on it, whereas an attached process
   is somebody else's, so there is no status of it for us to collect. *)
type origin =
  | Launched of { reaped : Unix.process_status option Atomic.t }
  | Attached

type subprocess = {
  alive : unit -> bool;
  cursor : Runtime_events.cursor;
  close : unit -> unit;
  origin : origin;
  pid : int;
  (* Path to the process's ring buffer file. The poller needs it to tell the
     ring's resident pages apart from the program's own memory. *)
  ring_file : string;
}

(* The child's own exit status, once it has been collected. [None] means "not
   yet known" for a launched process and "never knowable" for an attached one,
   and also covers a child that [close] had to terminate: a status we
   manufactured by killing it is not the child's own. *)
let exit_status t =
  match t.origin with
  | Launched { reaped } -> Atomic.get reaped
  | Attached -> None

type runtime_events_config = { log_wsize : int option; dir : string option }
type exec_config = Attach of string * int | Execute of string list

(* Raised by exec_process to indicate various unrecoverable failures. *)
exception Fail of string

let fail msg = raise (Fail msg)

(* How long to wait for a freshly launched child to initialise its ring
   buffers, and how often to check in the meantime.

   The child only creates its [<pid>.events] file while initialising the
   runtime, so the file does not exist yet just after the fork. How long it
   takes to appear depends on how quickly the child starts up: on macOS the
   first execution of a freshly built binary spends a few hundred
   milliseconds in the kernel (code signature validation) before any OCaml
   code runs. A fixed wait is therefore either flaky or needlessly slow, so
   we poll instead. *)
let ring_wait_timeout = 5.0
let ring_wait_interval = 0.005

let ring_file_of_pid dir pid =
  Filename.concat dir (string_of_int pid ^ ".events")

(* The runtime creates the ring file, then resizes it to its final size, then
   fills in the metadata header (see [runtime/runtime_events.c] in the OCaml
   distribution). A cursor created in between would either fail to map the
   file or, worse, succeed against an all-zero header and then report no
   events at all, so wait for the header to be written. [version] and
   [max_domains] are its first two fields, both non-zero once written. *)
let ring_header_ready ring_file =
  let prefix_len = 16 in
  match open_in_bin ring_file with
  | exception Sys_error _ -> false
  | ic ->
      Fun.protect
        ~finally:(fun () -> close_in_noerr ic)
        (fun () ->
          let buf = Bytes.create prefix_len in
          match really_input ic buf 0 prefix_len with
          (* The child wrote the header in this machine's native endianness. *)
          | () ->
              Bytes.get_int64_ne buf 0 <> 0L && Bytes.get_int64_ne buf 8 <> 0L
          | exception End_of_file -> false)

(* Wait for the child process [handle] to initialise its ring buffers and return
   a cursor on them. Raises [Fail] if the child dies first, or if it has not
   initialised them within [ring_wait_timeout]. *)
let create_cursor_when_ready ~dir ~pid ~(handle : Platform.handle) ~executable =
  let ring_file = ring_file_of_pid dir pid in
  let deadline = Unix.gettimeofday () +. ring_wait_timeout in
  let child_exited () =
    match Platform.waitpid [ Unix.WNOHANG ] handle with
    | None -> false
    | Some _ -> true
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> false
  in
  let rec wait () =
    if not (ring_header_ready ring_file) then retry None
    else
      match Runtime_events.create_cursor (Some (dir, pid)) with
      | cursor -> cursor
      | exception Failure msg -> retry (Some msg)
  and retry last_error =
    if child_exited () then
      fail
        (Printf.sprintf
           "%s exited before initialising its runtime events ring buffer %s. \
            Was it built with OCaml 5.0 or later?"
           executable ring_file)
    else if Unix.gettimeofday () >= deadline then begin
      (* We cannot monitor the child and are about to bail out, so do not
         leave it running behind us. *)
      ignore (Platform.terminate_and_reap handle);
      fail
        (Printf.sprintf
           "gave up after %.1fs waiting for %s to initialise its runtime \
            events ring buffer %s.%s Was it built with OCaml 5.0 or later?"
           ring_wait_timeout executable ring_file
           (match last_error with None -> "" | Some msg -> " " ^ msg))
    end
    else begin
      (try Unix.sleepf ring_wait_interval
       with Unix.Unix_error (Unix.EINTR, _, _) -> ());
      wait ()
    end
  in
  wait ()

let str_of_status status =
  let open Sys_backport in
  match status with
  | Unix.WEXITED code -> Printf.sprintf "exited with code %d" code
  | Unix.WSIGNALED sys_sig ->
      Printf.sprintf "killed by signal %s" (signal_to_string sys_sig)
  | Unix.WSTOPPED sys_sig ->
      Printf.sprintf "stopped by signal %s" (signal_to_string sys_sig)

let exec_process (config : runtime_events_config) (args : string list) :
    subprocess =
  if not (List.length args > 0) then
    fail @@ Printf.sprintf "no executable provided for exec_process";

  let executable_filename = List.hd args in

  let dir =
    match config.dir with
    | None -> Filename.get_temp_dir_name () |> Unix.realpath
    | Some path -> Unix.realpath path
  in
  if not @@ Sys.file_exists dir then
    fail @@ Printf.sprintf "directory %s does not exist" dir;
  if not @@ Sys.is_directory dir then
    fail @@ Printf.sprintf "file %s is not a directory" dir;

  let overridden_vars =
    "OCAML_RUNTIME_EVENTS_START" :: "OCAML_RUNTIME_EVENTS_DIR"
    :: "OCAML_RUNTIME_EVENTS_PRESERVE"
    ::
    (match config.log_wsize with
    | None -> []
    | Some _ -> [ "OCAMLRUNPARAM" ])
  in
  let base_env =
    Unix.environment () |> Array.to_seq
    |> Seq.filter (fun entry ->
        not
          (List.exists
             (fun var -> String.starts_with ~prefix:(var ^ "=") entry)
             overridden_vars))
    |> Array.of_seq
  in
  let env =
    Array.concat
      [
        [|
          (* See https://ocaml.org/manual/5.3/runtime-tracing.html#s:runtime-tracing-environment-variables *)
          "OCAML_RUNTIME_EVENTS_START=1";
          "OCAML_RUNTIME_EVENTS_DIR=" ^ dir;
          "OCAML_RUNTIME_EVENTS_PRESERVE=1";
        |];
        (* See https://ocaml.org/manual/5.3/runtime.html#s:ocamlrun-options *)
        (match config.log_wsize with
        | None -> [||]
        | Some i -> (
            let event_log = "e=" ^ Int.to_string i in
            match Sys.getenv_opt "OCAMLRUNPARAM" with
            | None -> [| "OCAMLRUNPARAM=" ^ event_log |]
            | Some params -> [| "OCAMLRUNPARAM=" ^ params ^ "," ^ event_log |]));
        base_env;
      ]
  in
  let child_pid, child_handle =
    let handle =
      try
        Platform.create_process_env executable_filename (Array.of_list args) env
          Unix.stdin Unix.stdout Unix.stderr
      with
      | Unix.Unix_error (Unix.ENOENT, _, _) ->
          raise
            (Fail (Printf.sprintf "executable %s not found" executable_filename))
      | Unix.Unix_error (err, fn, _) ->
          raise
            (Fail
               (Printf.sprintf "cannot execute %s: %s: %s" executable_filename
                  fn (Unix.error_message err)))
    in
    let pid =
      try Platform.pid_of_handle handle
      with Unix.Unix_error (err, fn, _) ->
        raise
          (Fail
             (Printf.sprintf "cannot determine the pid of %s: %s: %s"
                executable_filename fn (Unix.error_message err)))
    in
    (pid, handle)
  in
  let cursor =
    create_cursor_when_ready ~dir ~pid:child_pid ~handle:child_handle
      ~executable:executable_filename
  in
  (* used to avoid double reaping, which raises an exception other than ECHILD on windows *)
  let reaped = Atomic.make None in
  let ring_file = ring_file_of_pid dir child_pid in
  let alive () =
    (* on Windows, [waitpid] will fail if the process has been reaped *)
    if Option.is_some @@ Atomic.get reaped then false
    else
      match Platform.waitpid [ Unix.WNOHANG ] child_handle with
      | None -> true
      | Some _ as some_status ->
          Atomic.set reaped some_status;
          false
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> true
  and close () =
    let orphaned =
      if Option.is_some @@ Atomic.get reaped then false
      else
        match Platform.waitpid [ Unix.WNOHANG ] child_handle with
        | Some status ->
            Atomic.set reaped (Some status);
            false
        | None ->
            (* The child is still running. Do not leave it behind us, and note
               that the ring file stays mapped, and so cannot be unlinked on
               Windows, for as long as it lives. *)
            not (Platform.terminate_and_reap child_handle)
        | exception Unix.Unix_error (Unix.ECHILD, _, _) -> false
    in
    Runtime_events.free_cursor cursor;
    (* We need to remove the ring buffers ourselves because we told
       the child process not to remove them. However, if the user
       explicitly set OCAML_RUNTIME_EVENTS_PRESERVE=1 we honour
       their intent and leave the file in place. *)
    if Sys.getenv_opt "OCAML_RUNTIME_EVENTS_PRESERVE" <> Some "1" then
      if orphaned then
        Printf.eprintf
          "warning: could not terminate child %d, leaving %s behind\n%!"
          child_pid ring_file
      else Unix.unlink ring_file
  in
  {
    alive;
    cursor;
    close;
    origin = Launched { reaped };
    pid = child_pid;
    ring_file;
  }

let attach_process (dir : string) (pid : int) : subprocess =
  (* Check the target process exists before attempting to attach *)
  if not (Platform.is_process_alive ~pid) then
    fail @@ Printf.sprintf "process %d does not exist" pid;
  (* Check the events file exists and is readable *)
  let ring_file = ring_file_of_pid dir pid in
  if not (Sys.file_exists ring_file) then
    raise
      (Fail
         (Printf.sprintf
            "no events file found at %s. Is the target process running with \
             OCAML_RUNTIME_EVENTS_START=1?"
            ring_file));
  (try Unix.access ring_file [ Unix.R_OK ]
   with Unix.Unix_error (Unix.EACCES, _, _) ->
     raise
       (Fail
          (Printf.sprintf "events file %s is not readable by the current user"
             ring_file)));
  let cursor =
    try Runtime_events.create_cursor (Some (dir, pid))
    with Failure str -> fail (str ^ " Directory: " ^ dir)
  in
  let alive () = Platform.is_process_alive ~pid
  and close () = Runtime_events.free_cursor cursor in
  { alive; cursor; close; origin = Attached; pid; ring_file }

let launch_process config (exec_args : exec_config) : subprocess =
  match exec_args with
  | Execute argsl -> exec_process config argsl
  | Attach (dir, pid) -> attach_process dir pid

let interrupted = Atomic.make false

let collect_events ~sample_rss process_poller_sleep poll_sleep child callbacks =
  let old_handler =
    Sys.signal Sys.sigint
      (Sys.Signal_handle (fun _ -> Atomic.set interrupted true))
  in
  Fun.protect
    ~finally:(fun () -> Sys.set_signal Sys.sigint old_handler)
    (fun () ->
      Process_poller.start ~alive_check:child.alive ~pid:child.pid
        ~ring_file:child.ring_file ~interval:process_poller_sleep ~sample_rss;
      Fun.protect ~finally:Process_poller.stop (fun () ->
          (* Read from the child process *)
          while Process_poller.is_alive () && not (Atomic.get interrupted) do
            Runtime_events.read_poll child.cursor callbacks None |> ignore;
            if poll_sleep > 0.0 then
              try Unix.sleepf poll_sleep
              with Unix.Unix_error (Unix.EINTR, _, _) -> ()
          done;
          (* Do one more poll in case there are any remaining events we've missed *)
          Runtime_events.read_poll child.cursor callbacks None |> ignore))

type 'r acceptor_fn = int -> Runtime_events.Timestamp.t -> 'r

type consumer_config = {
  runtime_begin : (Runtime_events.runtime_phase -> unit) acceptor_fn;
  runtime_end : (Runtime_events.runtime_phase -> unit) acceptor_fn;
  runtime_counter : (Runtime_events.runtime_counter -> int -> unit) acceptor_fn;
  lifecycle : (Runtime_events.lifecycle -> int option -> unit) acceptor_fn;
  extra : Runtime_events.Callbacks.t -> Runtime_events.Callbacks.t;
  cleanup : unit -> unit;
  on_success : unit -> unit;
  process_poller_sleep : float;
  sample_rss : bool;
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
    cleanup = (fun () -> ());
    on_success = (fun _ -> ());
    process_poller_sleep = 0.1;
    sample_rss = true;
    poll_sleep = 0.1 (* Poll at 10Hz *);
    runtime_events_dir = None;
    (* Use default tmp directory *)
    runtime_events_log_wsize = None;
    (* Use default size 16. *)
  }

let olly config exec_args =
  Fun.protect ~finally:Lost_events.display (fun () ->
      let runtime_config =
        {
          dir = config.runtime_events_dir;
          log_wsize = config.runtime_events_log_wsize;
        }
      in
      let child = launch_process runtime_config exec_args in
      (* [cleanup] reports what was collected and undoes what [on_launch] set
         up, so it must only run once the child has actually been launched:
         otherwise it would print empty results and its own failure would mask
         the launch failure (as [Fun.Finally_raised]). *)
      Fun.protect ~finally:config.cleanup @@ fun () ->
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
            let lost_events = Lost_events.callback in
            Runtime_events.Callbacks.create ~runtime_begin ~runtime_end
              ~runtime_counter ~lifecycle ~lost_events ()
            |> extra
          in
          collect_events ~sample_rss:config.sample_rss
            config.process_poller_sleep config.poll_sleep child callbacks;
          config.on_success ());
      exit_status child
      |> Option.iter @@ function
         | Unix.WEXITED 0 -> ()
         | status -> fail @@ Printf.sprintf "Child %s" @@ str_of_status status)
