let () =
  let trace_cmd = Olly_trace.trace_cmd [(module Olly_format_json)] in
  Olly_common.Cli.main "olly_bare" [trace_cmd]
