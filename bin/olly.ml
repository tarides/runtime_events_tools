let () =
  let trace_cmd =
    Olly_trace.trace_cmd
      [ (module Olly_format_fuchsia); (module Olly_format_json) ]
  and gc_stats_cmd = Olly_gc_stats.gc_stats_cmd in
  Olly_common.Cli.main "olly" [ trace_cmd; gc_stats_cmd ]
