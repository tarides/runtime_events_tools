module type Format = sig
  type trace

  val name : string (* name for command line argument *)
  val description : string (* description for documentation *)

  val create : filename:string -> trace

  val close : trace -> unit
  val emit : trace -> Event.t -> unit
end

type format = (module Format)

type trace =
  { close : unit -> unit
  ; emit : Event.t -> unit }

let name (module Fmt : Format) = Fmt.name
let description (module Fmt : Format) = Fmt.description

let create (module Fmt : Format) ~filename =
  let tracer = Fmt.create ~filename in
  { close = (fun () -> Fmt.close tracer)
  ; emit = Fmt.emit tracer }

let close (trace : trace) = trace.close ()
let emit (trace : trace) event = trace.emit event

module Event = Event
