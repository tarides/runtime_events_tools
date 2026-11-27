val help_secs : [> `Noblank | `P of string | `S of string ] list
(** Man page sections shared by all commands. *)

val sdocs : string
(** Man page section where common options are documented. *)

val freq_option : float Cmdliner.Term.t
(** [--freq]: seconds to sleep between ring polls. *)

val ring_wait_timeout_option : float Cmdliner.Term.t
(** [--ring-wait-timeout]: total seconds to wait for the ring file to appear. *)

val ring_wait_interval_option : float Cmdliner.Term.t
(** [--ring-wait-interval]: seconds to sleep between checks for the ring file.
*)

val proc_stat_freq_option : float Cmdliner.Term.t
(** [--proc-stat-freq]: seconds between process status and peak RSS samples. *)

val runtime_events_dir : string option Cmdliner.Term.t
(** [--dir]: directory for the [.events] ring files. *)

val runtime_events_log_wsize : int option Cmdliner.Term.t
(** [--log-wsize]: log2 of the per-domain ring buffer size in words. *)

val exec_args : int -> Launch.exec_config Cmdliner.Term.t
(** [exec_args p] parses either an executable with arguments starting at
    positional [p], or [--attach]. *)

val main : string -> unit Cmdliner.Cmd.t list -> 'a
(** [main name cmds] evaluates the command group [name] and exits. *)
