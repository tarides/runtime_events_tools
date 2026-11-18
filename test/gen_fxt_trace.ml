(* Writes a sample trace through the fuchsia backend, with every kind of event olly emits.

   Produces three variants depending on the first argument:
    - simple : a simple trace exercising spans and counters
    - long_repeat : a long trace to check buffering
    - many_names : a long trace with many event names to test table allocation
    
   Improvement ideas:
    - some more complex scenario
    - do the same for the JSON output
    - somehow check consistency of the JSON and FXT output *)

open Olly_format_backend.Event

let () =
  let variant, filename =
    match Sys.argv with
    | [| _; "long_repeat"; file |] -> (`Long_repeat, file)
    | [| _; "many_names"; file |] -> (`Many_names, file)
    | [| _; "simple"; file |] -> (`Simple, file)
    | _ ->
        prerr_endline
          "usage: gen_fxt_trace (simple|long_repeat|many_names) FILE";
        exit 2
  in
  let trace =
    Olly_format_fuchsia.create ~filename
      ~max_domains:Olly_common.Launch.max_domains
  in
  let ts = ref 9_876L in
  let tick () =
    ts := Int64.add !ts 321L;
    !ts
  in
  let emit ring_id name kind =
    Olly_format_fuchsia.emit trace ~ring_id ~ts:(tick ()) ~name ~kind
  in
  let counter ring_id name value =
    Olly_format_fuchsia.emit_counter trace ~ring_id ~ts:(tick ()) ~name ~value
  in
  (match variant with
  | `Long_repeat ->
      for i = 0 to 59_999 do
        let ring_id = i mod 300 in
        emit ring_id "test_span" SpanBegin;
        counter ring_id "test_counter" i;
        emit ring_id "test_span" SpanEnd
      done
  | `Many_names ->
      for i = 0 to 128_000 do
        counter 0 ("counter_" ^ string_of_int i) i
      done
  | `Simple ->
      (* Nested spans: on the first domains, and on the last domain supported. *)
      List.iter
        (fun ring_id ->
          emit ring_id "sample_span_one" SpanBegin;
          emit ring_id "sample_span_two" SpanBegin;
          emit ring_id "sample_span_two" SpanEnd;
          emit ring_id "sample_span_one" SpanEnd)
        [ 0; 1; Olly_common.Launch.max_domains - 1 ];
      (* Runtime counters, around the int32 boundary. *)
      counter 0 "sample_counter_one" 0;
      counter 1 "sample_counter_one" 42;
      counter 1 "sample_counter_two" 0x7fff_ffff;
      counter 1 "sample_counter_two" 0x8000_0000;
      counter 127 "sample_counter_three" (1 lsl 40);
      (* Custom events: an int one goes through [emit] with a [Counter] kind. *)
      emit 0 "custom_int" (Counter 7);
      emit 1 "custom_unit" Instant);
  Olly_format_fuchsia.close trace
