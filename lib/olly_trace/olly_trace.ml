module Format = Olly_format_backend

let trace ~ring_wait_timeout ~ring_wait_interval ~process_poller_sleep
    ~poll_sleep ~fmt ~trace_filename ~emit_counter ~runtime_events_dir
    ~runtime_events_log_wsize exec_args =
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
  and cleanup () = Format.close tracer
  and extra = Olly_custom_events.v tracer in
  let open Olly_common.Launch in
  try
    `Ok
      (olly
         {
           extra;
           runtime_begin;
           runtime_counter;
           runtime_end;
           lifecycle = (fun _ _ _ _ -> ());
           cleanup;
           on_success = (fun () -> ());
           process_poller_sleep;
           sample_rss = false;
           poll_sleep;
           runtime_events_dir;
           runtime_events_log_wsize;
           ring_wait_timeout;
           ring_wait_interval;
         }
         exec_args)
  with Fail msg -> `Error (false, msg)

let trace_cmd format_list =
  let open Cmdliner in
  let open Olly_common.Cli in
  let trace_filename =
    let doc = "Target trace file name." in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"TRACEFILE" ~doc)
  in

  let emit_counter =
    let doc =
      "Emit runtime counter events. All counters defined by the OCaml runtime \
       in use are emitted, so the set varies by OCaml version. See \
       https://ocaml.org/manual/runtime-tracing.html and \
       https://ocaml.org/manual/latest/api/Runtime_events.html for what each \
       counter measures."
    in
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
  let open Term.Syntax in
  Cmd.v info @@ Term.ret
  @@
  let+ ring_wait_timeout = ring_wait_timeout_option
  and+ ring_wait_interval = ring_wait_interval_option
  and+ process_poller_sleep = proc_stat_freq_option
  and+ poll_sleep = freq_option
  and+ fmt = format_option
  and+ trace_filename = trace_filename
  and+ emit_counter = emit_counter
  and+ runtime_events_dir = runtime_events_dir
  and+ runtime_events_log_wsize = runtime_events_log_wsize
  and+ exec_args = exec_args 1 in
  trace ~ring_wait_timeout ~ring_wait_interval ~process_poller_sleep ~poll_sleep
    ~fmt ~trace_filename ~emit_counter ~runtime_events_dir
    ~runtime_events_log_wsize exec_args
