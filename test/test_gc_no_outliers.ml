open Olly_gc_stats

let ok_or_exn = function Ok r -> r | Error e -> failwith e

let () =
  let file = Sys.argv.(1) in
  In_channel.with_open_bin file @@ fun ch ->
  let reader = Bytesrw.Bytes.Reader.of_in_channel ch in
  let t =
    Jsont_bytesrw.decode ~locs:true ~file Json.Gc_stats.jsont reader
    |> ok_or_exn
  in
  let gc_times =
    t.Json.Gc_stats.domain_stats
    |> List.map (fun (_, (ds : Json.Gc_stats.domain_stat)) ->
        ds.Json.Gc_stats.gc_time)
    |> List.sort Float.compare
  in
  let (_ : float) =
    List.fold_left
      (fun prev current ->
        (* in the original bug the difference was >10x,
           where we missed an entire GC event type on Domain 0.
           If this fails then look at 'olly trace' in Perfetto,
           and see whether it is expected that Domain 0 truly takes less time,
           perhaps due to a change in the OCaml runtime *)
        if prev < current /. 5. then begin
          Printf.eprintf "previous GC time %gs << current GC time %gs\n" prev
            current;
          List.iter (Printf.eprintf "GC time: %gs\n") gc_times;
          exit 1
        end;
        current)
      Float.max_float gc_times
  in
  ()
