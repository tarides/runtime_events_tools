let gc_stats_cmd =
  let open Cmdliner in
  let open Olly_common.Cli in
  let json_option =
    let doc = "Print the output in json instead of human-readable format." in
    Arg.(value & flag & info [ "json" ] ~docv:"json" ~doc)
  in

  let output_option =
    let doc =
      "Redirect the output of `olly` to specified file. The output of the \
       command is not redirected."
    in
    Arg.(
      value
      & opt (some string) None
      & info [ "o"; "output" ] ~docv:"output" ~doc)
  in

  let man =
    [
      `S Manpage.s_description;
      `P "Report the GC latency profile.";
      `I ("Wall time", "Real execution time of the program");
      `I ("CPU time", "Total CPU time across all domains");
      `I
        ( "GC time",
          "Total time spent by the program performing garbage collection \
           (major and minor)" );
      `I
        ( "GC overhead",
          "Percentage of time taken up by GC against the total execution time"
        );
      `I
        ( "GC time per domain",
          "Time spent by every domain performing garbage collection (major and \
           minor cycles). Domains are reported with their domain ID   (e.g. \
           `Domain 0`)" );
      `I
        ( "GC latency profile",
          "Mean, standard deviation and percentile latency profile of GC \
           events." );
      `I
        ( "GC allocations",
          "GC allocation and promotion in machine words during program \
           execution. Counts of Compactions, and Minor and Major collections."
        );
      `Blocks help_secs;
    ]
  in
  let doc = "Report the GC latency profile and stats." in
  let info = Cmd.info "gc-stats" ~doc ~sdocs ~man in

  Cmd.v info
    Term.(
      ret
        (const Olly_gc_impl.gc_stats
        $ freq_option $ json_option $ output_option $ runtime_events_dir
        $ runtime_events_log_wsize $ exec_args 0))

let latency_cmd =
  let open Cmdliner in
  let open Olly_common.Cli in
  let json_option =
    let doc = "Print the output in json instead of human-readable format." in
    Arg.(value & flag & info [ "json" ] ~docv:"json" ~doc)
  in

  let output_option =
    let doc =
      "Redirect the output of `olly` to specified file. The output of the \
       command is not redirected."
    in
    Arg.(
      value
      & opt (some string) None
      & info [ "o"; "output" ] ~docv:"output" ~doc)
  in

  let man =
    [
      `S Manpage.s_description;
      `P
        "Report the GC latency profile. This includes mean, standard deviation \
         and percentile latency profile of GC events.";
      `Blocks help_secs;
    ]
  in
  let doc = "Report the GC latency profile." in
  let info = Cmd.info "latency" ~doc ~sdocs ~man in

  Cmd.v info
    Term.(
      ret
        (const Olly_gc_impl.latency $ freq_option $ json_option $ output_option
       $ runtime_events_dir $ exec_args 0))
