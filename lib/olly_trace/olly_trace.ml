module Format = Olly_format_backend

let trace poll_sleep fmt trace_filename emit_counter runtime_events_dir
    runtime_events_log_wsize exec_args =
  let open Format.Event in
  let tracer = Format.create fmt ~filename:trace_filename in
  let runtime_phase kind ring_id ts phase =
    Format.emit tracer
      {
        name = Runtime_events.runtime_phase_name phase;
        ts = Runtime_events.Timestamp.to_int64 ts;
        ring_id;
        kind;
      }
  in
  let runtime_counter ring_id ts counter value =
    if emit_counter then
      Format.emit tracer
        {
          name = Runtime_events.runtime_counter_name counter;
          ts = Runtime_events.Timestamp.to_int64 ts;
          ring_id;
          kind = Counter value;
        }
    else ()
  in
  let runtime_begin = runtime_phase SpanBegin
  and runtime_end = runtime_phase SpanEnd
  and init () = ()
  and cleanup () = Format.close tracer
  and extra = Olly_custom_events.v tracer
  and lifecycle _ _ _ _ = () in
  let open Olly_common.Launch in
  olly
    {
      extra;
      runtime_begin;
      runtime_counter;
      runtime_end;
      lifecycle;
      init;
      cleanup;
      poll_sleep;
      runtime_events_dir;
      runtime_events_log_wsize;
    }
    exec_args

let trace_cmd format_list =
  let open Cmdliner in
  let open Olly_common.Cli in
  let trace_filename =
    let doc = "Target trace file name." in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"TRACEFILE" ~doc)
  in

  let emit_counter =
    let doc = "Emit runtime counter events." in
    Arg.(value & flag & info [ "c"; "emit-counters" ] ~doc)
  in

  let format_option =
    let doc =
      "Format of the target trace, options are: "
      ^ (List.map
           (fun fmt ->
             Printf.sprintf "\"%s\" (%s)" (Format.name fmt)
               (Format.description fmt))
           format_list
        |> String.concat ", ")
      ^ "."
    in
    Arg.(
      value
      & opt
          (enum (List.map (fun fmt -> (Format.name fmt, fmt)) format_list))
          (List.hd format_list)
      & info [ "f"; "format" ] ~docv:"format" ~doc)
  in
  let man =
    [
      `S Manpage.s_description;
      `P "Save the runtime trace to file.";
      `Blocks help_secs;
    ]
  in
  let doc = "Save the runtime trace to file." in
  let info = Cmd.info "trace" ~doc ~sdocs ~man in
  Cmd.v info
    Term.(
      const trace $ freq_option $ format_option $ trace_filename $ emit_counter
      $ runtime_events_dir $ runtime_events_log_wsize $ exec_args 1)
