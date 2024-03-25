let () =
  let trace_cmd = Olly_trace.trace_cmd [(module Olly_format_json)] in
  Olly_common.main [trace_cmd]
