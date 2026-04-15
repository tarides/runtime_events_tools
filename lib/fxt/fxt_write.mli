(** Minimal FXT (Fuchsia trace format) writer.

    Writes trace events in the binary FXT format used by
    {{:https://ui.perfetto.dev/} Perfetto}. Designed for zero-allocation
    in the steady state: string and thread references are interned on first
    use, then subsequent events for the same name/thread emit only a
    compact index.

    Event headers are packed via C stubs (see {!Fxt_buf}) to avoid
    {!Int64} boxing from OCaml's bitwise operations.

    Modeled on the FXT writer in
    {{:https://github.com/ocaml-multicore/eio-trace} eio-trace}.

    @see <https://fuchsia.dev/fuchsia-src/reference/tracing/trace-format> *)

(** An FXT trace writer. Writes to an {!out_channel} via an internal
    64KB buffer. *)
type t

(** A thread identity, represented as a process/thread ID pair. In olly,
    each OCaml domain is mapped to a distinct [pid] with [tid = 0]. *)
type thread = {
  pid : int64;
  tid : int64;
}

val create : out_channel -> t
(** [create oc] initialises a new FXT trace writer on [oc]. Writes the
    FXT magic number and initialisation record (1 tick = 1 nanosecond)
    immediately. *)

val close : t -> unit
(** [close t] flushes any buffered data and closes the output channel. *)

val duration_begin : t -> thread:thread -> name:string -> ts:int64 -> unit
(** [duration_begin t ~thread ~name ~ts] emits a duration-begin event. *)

val duration_end : t -> thread:thread -> name:string -> ts:int64 -> unit
(** [duration_end t ~thread ~name ~ts] emits a duration-end event. *)

val instant : t -> thread:thread -> name:string -> ts:int64 -> unit
(** [instant t ~thread ~name ~ts] emits an instant event. *)

val counter : t -> thread:thread -> name:string -> ts:int64 -> value:int -> unit
(** [counter t ~thread ~name ~ts ~value] emits a counter event with a
    single integer argument named ["v"]. *)
