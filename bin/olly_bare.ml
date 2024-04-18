let () =
  let trace_cmd = Olly_trace.trace_cmd [ (module Olly_format_json) ]
  and gen_tables_cmd = Olly_gen_tables.cmd in
  Olly_common.Cli.main "olly_bare" [ trace_cmd; gen_tables_cmd ]
