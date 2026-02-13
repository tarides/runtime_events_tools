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

let runtime_events_dir =
  let doc =
    "Sets the directory where the .events files containing the runtime event \
     tracing system’s ring buffers will be located.\n\n\
    \               If not specified a temporary directory will be used."
  in
  Arg.(value & opt (some string) None & info [ "d"; "dir" ] ~docv:"dir" ~doc)

let runtime_events_log_wsize =
  let doc =
    "Size of the per-domain runtime events ring buffers in log powers of two \
     words. Defaults to 16."
  in
  Arg.(
    value & opt (some int) None & info [ "log-wsize" ] ~docv:"log-wsize" ~doc)

let freq_option =
  let doc =
    "Set the interval that olly sleeps in seconds, after performing a \
     [Runtime_events.read_poll]. Fractions of seconds are supported. A value \
     of 0.0 will skip sleeping altogether."
  in
  Arg.(
    value
    & opt float 0.1 (* Poll at 10Hz by default. *)
    & info [ "freq" ] ~docv:"freq" ~doc)

let exec_args p =
  let exec_and_args, ea_docv =
    let doc = "Executable and arguments to trace." in
    let docv = "EXECUTABLE" in
    Term.
      ( (const List.concat
        $ Arg.(
            value
            & pos_right (p - 1) (list ~sep:' ' string) []
            & info [] ~docv ~doc)),
        docv )
  in
  let attach_opt, ao_docv =
    let doc =
      "Attach to the process with the given PID. The directory containing the \
       PID.events file may be specified. This option cannot be combined with \
       EXECUTABLE."
    in
    let docv = "[directory:]pid" in
    let parser str =
      let exception Fail of string in
      try
        let dir, pid_str =
          match String.rindex_opt str ':' with
          | None -> (".", str)
          | Some idx ->
              ( String.sub str 0 idx,
                String.sub str (idx + 1) (String.length str - idx - 1) )
        in
        let pid =
          try int_of_string pid_str
          with _ ->
            raise (Fail (Printf.sprintf "expected integer pid, got %s" pid_str))
        in
        if not @@ Sys.file_exists dir then
          raise (Fail (Printf.sprintf "directory %s does not exist" dir));
        if not @@ Sys.is_directory dir then
          raise (Fail (Printf.sprintf "file %s is not a directory" dir));
        Ok (dir, pid)
      with Fail msg -> Error msg
    in
    let printer fmt (dir, pid) =
      match dir with
      | "." -> Format.fprintf fmt "%d" pid
      | _ -> Format.fprintf fmt "%s:%d" dir pid
    in
    let dir_and_pid_conv = Arg.conv' ~docv (parser, printer) in
    ( Arg.(
        value
        & opt (some dir_and_pid_conv) None
        & info [ "a"; "attach" ] ~docv ~doc),
      docv )
  in
  let cat_docvs sep = Printf.sprintf "%s %s --attach=%s" ea_docv sep ao_docv in
  let combine dir_and_pid args =
    match (args, dir_and_pid) with
    | [], Some (dir, pid) -> Ok (Launch.Attach (dir, pid))
    | _ :: _, None -> Ok (Launch.Execute args)
    | [], None ->
        Error (Printf.sprintf "required %s is missing" (cat_docvs "or"))
    | _ ->
        Error (Printf.sprintf "more than one of %s specified" (cat_docvs "and"))
  in
  Term.(term_result' ~usage:true (const combine $ attach_opt $ exec_and_args))

let main name commands =
  let main_cmd =
    let doc = "An observability tool for OCaml programs" in
    let info = Cmd.info name ~doc ~sdocs in
    Cmd.group info commands
  in

  exit (Cmd.eval main_cmd)
