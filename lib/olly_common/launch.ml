open Olly_rte_shim
open Event

let lost_events ring_id num =
  Printf.eprintf "[ring_id=%d] Lost %d events\n%!" ring_id num

type subprocess = {
  alive : unit -> bool;
  cursor : Runtime_events.cursor;
  close : unit -> unit;
}

let exec_process exec_args =
  let argsl = String.split_on_char ' ' exec_args in
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

let collect_events child callbacks =
  (* Read from the child process *)
  while child.alive () do
    Runtime_events.read_poll child.cursor callbacks None |> ignore;
    Unix.sleepf 0.1 (* Poll at 10Hz *)
  done;
  (* Do one more poll in case there are any remaining events we've missed *)
  Runtime_events.read_poll child.cursor callbacks None |> ignore

type consumer_config = {
  handler : shim_callback;
  init : unit -> unit;
  cleanup : unit -> unit;
}

let empty_config =
  { handler = (fun _ -> ()); init = (fun () -> ()); cleanup = (fun () -> ()) }

type common_args = { exec_args : string; src_table_path : string option }

let our_handler (k : shim_callback) (evt : event) =
  match evt.tag with
  | Lost_events -> (
      match evt.kind with Counter num -> lost_events evt.ring_id num | _ -> ())
  | _ -> k evt

let make_shim_callback src_table_path handler =
  let map_names =
    match src_table_path with
    | None -> Construct.builtin_names
    | Some path -> Construct.tabled_names (Tabling.parse_from_yaml_file path)
  in
  our_handler (map_names handler)

let olly config { exec_args; src_table_path } =
  config.init ();
  Fun.protect ~finally:config.cleanup (fun () ->
      let child = exec_process exec_args in
      Fun.protect ~finally:child.close (fun () ->
          let cb = make_shim_callback src_table_path config.handler in
          let callbacks = Construct.make_callbacks cb in
          collect_events child callbacks))
