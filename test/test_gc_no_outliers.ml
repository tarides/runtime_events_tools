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
  in
  let count = List.length gc_times in
  let avg = List.fold_left ( +. ) 0. gc_times /. float_of_int count in
  t.Json.Gc_stats.domain_stats
  |> List.iter @@ fun (d, (ds : Json.Gc_stats.domain_stat)) ->
     let gc_time = ds.Json.Gc_stats.gc_time in
     if gc_time < avg /. 4. then begin
       Printf.eprintf "GC time for domain %s (%gs) << average GC time(%gs)\n" d
         gc_time avg;
       exit 1
     end
