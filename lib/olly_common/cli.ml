open Cmdliner

let help_secs =
  [
    `S Manpage.s_common_options;
    `P "These options are common to all commands.";
    `S "MORE HELP";
    `P "Use $(mname) $(i,COMMAND) --help for help on a single command.";
    `Noblank;
    `S Manpage.s_bugs;
    `P
      "Check bug reports at \
       http://github.com/tarides/runtime_events_tools/issues.";
  ]

let sdocs = Manpage.s_common_options

let help man_format cmds topic =
  match topic with
  | None -> `Help (`Pager, None) (* help about the program. *)
  | Some topic -> (
      let topics = "topics" :: cmds in
      let conv, _ = Cmdliner.Arg.enum (List.rev_map (fun s -> (s, s)) topics) in
      match conv topic with
      | `Error e -> `Error (false, e)
      | `Ok t when t = "topics" ->
          List.iter print_endline topics;
          `Ok ()
      | `Ok t when List.mem t cmds -> `Help (man_format, Some t)
      | `Ok _t ->
          let page =
            ((topic, 7, "", "", ""), [ `S topic; `P "Say something" ])
          in
          `Ok (Manpage.print man_format Format.std_formatter page))

let exec_args p =
  let doc =
    "Executable (and its arguments) to trace. If the executable takes\n\
    \              arguments, wrap quotes around the executable and its \
     arguments.\n\
    \              For example, olly '<exec> <arg_1> <arg_2> ... <arg_n>'."
  in
  Arg.(required & pos p (some string) None & info [] ~docv:"EXECUTABLE" ~doc)

let src_table_args =
  let doc =
    "Load a runtime events name table for event translation, for forwards \
     compatibility with newer OCaml versions.\n\
     See `olly-gen-tables`."
  in
  Arg.(
    value & opt (some non_dir_file) None & info [ "table" ] ~docv:"PATH" ~doc)

let common_args p =
  let combine src_table_path exec_args : Launch.common_args =
    { src_table_path; exec_args }
  in
  Term.(const combine $ src_table_args $ exec_args p)

let main name commands =
  let help_cmd =
    let topic =
      let doc = "The topic to get help on. $(b,topics) lists the topics." in
      Arg.(value & pos 0 (some string) None & info [] ~docv:"TOPIC" ~doc)
    in
    let doc = "Display help about olly and olly commands." in
    let man =
      [
        `S Manpage.s_description;
        `P "Prints help about olly commands and other subjects…";
        `Blocks help_secs;
      ]
    in
    let info = Cmd.info "help" ~doc ~man in
    Cmd.v info
      Term.(ret (const help $ Arg.man_format $ Term.choice_names $ topic))
  in

  let main_cmd =
    let doc = "An observability tool for OCaml programs" in
    let info = Cmd.info name ~doc ~sdocs in
    Cmd.group info (commands @ [ help_cmd ])
  in

  exit (Cmd.eval main_cmd)
