(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*                          Sadiq Jaffer, Opsian                          *)
(*                                                                        *)
(*   Copyright 2021 Opsian Ltd                                            *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

type t
(** Abstract timestamp included in events. *)

val to_int64 : t -> int64
(** Convert a timestamp to a number of nanosecond.

    Note that the starting point for timestamps in unspecified: the absolute
    value is meaningless, only differences matter.

    Also note that the precision of the underlying clock may be coarser than
    nanoseconds: events may have equal timestamp if they are emitted within the
    coarseness of the clock. *)

val get_current : unit -> t
(** Access the current timestamp. *)
