module Lost_events : sig
  val were_events_lost : unit -> bool
end

type origin

type subprocess = {
  alive : unit -> bool;
  cursor : Runtime_events.cursor;
  close : unit -> unit;
  origin : origin;
  pid : int;
}

type runtime_events_config = { log_wsize : int option; dir : string option }
type exec_config = Attach of string * int | Execute of string list

exception Fail of string

(* Exposed for [test_launch]: the tests exercise process launching directly,
   without going through [olly]. *)
val exec_process : runtime_events_config -> string list -> subprocess

val create_cursor_when_ready :
  dir:string ->
  pid:int ->
  handle:Platform.handle ->
  executable:string ->
  Runtime_events.cursor
(** Wait for the child [handle] to initialise its ring buffer and return a
    cursor on it. Raises [Fail] if the child dies first, or does not initialise
    it in time.

    Also exposed for [test_launch], which drives it with a child whose ring
    buffer appears late. That cannot be arranged through [exec_process], which
    always sets OCAML_RUNTIME_EVENTS_START, and so has the runtime create the
    ring buffer before the child runs any code of its own. *)

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

val empty_config : consumer_config
val olly : consumer_config -> exec_config -> unit
