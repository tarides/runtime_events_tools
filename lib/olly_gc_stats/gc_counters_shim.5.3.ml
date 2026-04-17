(* OCaml 5.3 / 5.4: minor allocation counters report bytes, so convert to
   words. EV_C_MAJOR_ALLOCATED_WORDS already reports words. *)
let bytes_per_word = Sys.word_size / 8

let runtime_counter ~domain_minor_words ~domain_promoted_words
    ~domain_major_words ring_id _ts counter_type value =
  match counter_type with
  | Runtime_events.EV_C_MINOR_PROMOTED ->
      domain_promoted_words.(ring_id) <-
        domain_promoted_words.(ring_id) + (value / bytes_per_word)
  | Runtime_events.EV_C_MINOR_ALLOCATED ->
      domain_minor_words.(ring_id) <-
        domain_minor_words.(ring_id) + (value / bytes_per_word)
  | Runtime_events.EV_C_MAJOR_ALLOCATED_WORDS ->
      domain_major_words.(ring_id) <- domain_major_words.(ring_id) + value
  | _ -> ()
