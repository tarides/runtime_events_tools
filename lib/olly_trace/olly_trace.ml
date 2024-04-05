module Format = Olly_format_backend

let trace fmt trace_filename exec_args =
  let tracer = Format.create fmt ~filename:trace_filename in
  let handler evt = Format.emit tracer evt
  and init () = ()
  and cleanup () = Format.close tracer in
  Olly_common.Launch.olly { handler; init; cleanup } exec_args

let trace_cmd format_list =
  let open Cmdliner in
  let open Olly_common.Cli in
  let trace_filename =
    let doc = "Target trace file name." in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"TRACEFILE" ~doc)
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
  Cmd.v info Term.(const trace $ format_option $ trace_filename $ common_args 1)
