(* OCaml 5.5+: prefer the word-sized minor counters added in ocaml/ocaml#14189.
   The legacy bytes counters (EV_C_MINOR_ALLOCATED / EV_C_MINOR_PROMOTED) are
   still emitted for backwards compatibility — we must ignore them here to
   avoid double-counting. *)
let runtime_counter ~domain_minor_words ~domain_promoted_words
    ~domain_major_words ring_id _ts counter_type value =
  match counter_type with
  | Runtime_events.EV_C_MINOR_PROMOTED_WORDS ->
      domain_promoted_words.(ring_id) <-
        domain_promoted_words.(ring_id) + value
  | Runtime_events.EV_C_MINOR_ALLOCATED_WORDS ->
      domain_minor_words.(ring_id) <- domain_minor_words.(ring_id) + value
  | Runtime_events.EV_C_MAJOR_ALLOCATED_WORDS ->
      domain_major_words.(ring_id) <- domain_major_words.(ring_id) + value
  | _ -> ()
