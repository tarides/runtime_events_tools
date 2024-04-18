let enum_re = Str.regexp {|typedef enum {\([^}]*\)} \([a-z_]+\);|}
let enum_constant_re = Str.regexp {|\(EV_\(C_\)?\)?\([A-Z_]+\)|}

let enums_of_concern =
  [
    ("ev_lifecycle", "lifecycle");
    ("ev_runtime_phase", "phase");
    ("ev_runtime_counter", "counter");
  ]

let parse_constants constants_str =
  let ls = ref [] in
  try
    let i = ref 0 in
    while true do
      ignore (Str.search_forward enum_constant_re constants_str !i);
      i := Str.match_end ();
      let constant_value = Str.matched_group (* name *) 3 constants_str in
      let name = String.lowercase_ascii constant_value in
      ls := name :: !ls
    done;
    !ls
  with Not_found -> List.rev !ls

(** parse the enum from runtime_events.h *)
let parse_tables_from_header source_str =
  let state = Hashtbl.create 4 in
  try
    let i = ref 0 in
    while true do
      ignore (Str.search_forward enum_re source_str !i);
      i := Str.match_end ();
      let enum_name = Str.matched_group (* name *) 2 source_str
      and enum_constants = Str.matched_group (* constant list *) 1 source_str in
      try
        let name = List.assoc enum_name enums_of_concern in
        Hashtbl.add state name (parse_constants enum_constants)
      with Not_found -> ()
    done;
    state
  with Not_found -> state

let parse_tables_from_file file_name =
  let source_str = In_channel.(with_open_text file_name input_all) in
  parse_tables_from_header source_str

type out_fmt = Ml | Yaml

let stringify fmt state =
  let make_array name =
    try
      let cnsts = Hashtbl.find state name in
      match fmt with
      | Ml ->
          Printf.sprintf "let %s_names = [|\n%s\n|]\n\n" name
            (String.concat ";\n" (List.map (Printf.sprintf "  \"%s\"") cnsts))
      | Yaml -> Printf.sprintf "%s: [%s]\n" name (String.concat "," cnsts)
    with Not_found ->
      Printf.eprintf "Did not find enum: %s\n" name;
      exit 1
  in
  match fmt with
  | Ml ->
      Printf.sprintf
        "open Tabling\n\n\
         %slet name_table = { lifecycle_names ; phase_names ; counter_names }\n"
        (make_array "lifecycle" ^ make_array "phase" ^ make_array "counter")
  | Yaml -> make_array "lifecycle" ^ make_array "phase" ^ make_array "counter"

let output_to maybe_file str =
  match maybe_file with
  | None -> print_string str
  | Some file_name ->
      Out_channel.(with_open_text file_name (fun oc -> output_string oc str))

let cmd =
  let open Cmdliner in
  let header_file_arg p =
    let doc =
      "Path to `caml/runtime_events.h`, e.g. \"\\$(ocamlc \
       -where)/caml/runtime_events.h\"."
    in
    Arg.(required & pos p (some non_dir_file) None & info [] ~docv:"FILE" ~doc)
  in

  let stringify_fmt_arg =
    let doc =
      "Format to produce output, options: \"ml\" (OCaml .ml source file) \
       \"yaml\" (a subset of YAML)."
    in
    Arg.(
      value
      & opt (enum [ ("ml", Ml); ("yaml", Yaml) ]) Yaml
      & info [ "f"; "format" ] ~docv:"FORMAT" ~doc)
  in

  let output_dst_arg =
    let doc = "Redirect output to the specified file." in
    Arg.(
      value & opt (some string) None & info [ "o"; "output" ] ~docv:"FILE" ~doc)
  in

  let cmd =
    let doc = "Generate runtime events name tables" in
    let info = Cmd.info "gen-tables" ~doc ~sdocs:Manpage.s_common_options in
    Cmd.v info
      Term.(
        const output_to $ output_dst_arg
        $ (const stringify $ stringify_fmt_arg
          $ (const parse_tables_from_file $ header_file_arg 0)))
  in
  cmd
