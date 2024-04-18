open Event

type raw_name_table = {
  lifecycle_names : string array;
  phase_names : string array;
  counter_names : string array;
}

exception Not_an_int

let enum_to_int (e : 'a) : int =
  if not (Obj.is_int (Obj.repr e)) then raise Not_an_int;
  let idx : int = Obj.magic e in
  idx

let lookup_name (sa : string array) (e : 'a) : string = sa.(enum_to_int e)

let parse_from_yaml yaml_lines =
  let lc, ph, cnt = (ref None, ref None, ref None) in
  let parse_line line =
    (* line format: "name: [evt1_name,evt2_name,evt3_name]" *)
    let colon_i = String.index line ':' in
    let name = String.sub line 0 colon_i in
    let constants_start_i = colon_i + 3 in
    let constants_length = String.length line - constants_start_i - 1 in
    let constants_str = String.sub line constants_start_i constants_length in
    let constants = String.split_on_char ',' constants_str in
    let rf =
      match name with
      | "lifecycle" -> lc
      | "phase" -> ph
      | "counter" -> cnt
      | _ -> ref None
    in
    rf := Some (Array.of_list constants)
  in
  List.iter parse_line yaml_lines;
  {
    lifecycle_names = Option.get !lc;
    phase_names = Option.get !ph;
    counter_names = Option.get !cnt;
  }

let parse_from_yaml_file path =
  let lines = In_channel.(with_open_text path input_lines) in
  parse_from_yaml lines

(** Read the names of the [runtime_phase], [runtime_counter] and [lifecycle]
    events from a table, which allows translating runtime events from future
    OCaml versions. *)
let tabled_names (table : raw_name_table) (k : shim_callback) (evt : event) :
    unit =
  k
  @@
  try
    match evt.tag with
    | Runtime_phase ph -> { evt with name = lookup_name table.phase_names ph }
    | Runtime_counter cnt ->
        { evt with name = lookup_name table.counter_names cnt }
    | Lifecycle lc -> { evt with name = lookup_name table.lifecycle_names lc }
    | _ -> evt
  with Invalid_argument _ -> evt

(** Make an array the same size as `input`, with each entry the index
    of the corresponding string in `output` (the "known events"),
    unmapped events will map to -1, indicating that the event should
    be dropped. *)
let build_int_map (input : string array) (output : string array) : int array =
  let idx_map : (string, int) Hashtbl.t =
    Hashtbl.create (Array.length output)
  in
  let insert_out_name idx name = Hashtbl.add idx_map name idx in
  Array.iteri insert_out_name output;
  let lookup_in_name name =
    try Hashtbl.find idx_map name with Not_found -> -1
  in
  Array.map lookup_in_name input

exception Not_mapped

let translate_table (src_tag : 'a) (mapping : int array) (k : 'a -> 'b) : 'b =
  let new_idx =
    try mapping.(enum_to_int src_tag)
    with Invalid_argument _ -> raise Not_mapped
  in
  if new_idx = -1 then raise Not_mapped;
  (* safety: input was an int (and possibly an invalid value), output is too *)
  let new_tag : 'a = Obj.magic new_idx in
  k new_tag

(** Translate the tags of [runtime_phase], [runtime_counter] and [lifecycle]
    events by name using two tables, which allows us to [match] on them using
    the currently-compiled OCaml version's values, even if those differ
    (bit-wise) from those produced by the program we're attached to.
    Unrecognised events (i.e. new ones) will have their tag replaced by
    [Unrecognised], in the absence of a better alternative. Olly tools
    (e.g. trace) can still use the associated name and data. *)
let tabled_tags ~(actual : raw_name_table) ~(builtin : raw_name_table)
    (k : shim_callback) : shim_callback =
  let lcm, phm, cntm =
    ( build_int_map actual.lifecycle_names builtin.lifecycle_names,
      build_int_map actual.phase_names builtin.phase_names,
      build_int_map actual.counter_names builtin.counter_names )
  in
  fun evt ->
    k
    @@
    try
      match evt.tag with
      | Lifecycle lc_in ->
          translate_table lc_in lcm (fun lc -> { evt with tag = Lifecycle lc })
      | Runtime_phase ph_in ->
          translate_table ph_in phm (fun ph ->
              { evt with tag = Runtime_phase ph })
      | Runtime_counter cnt_in ->
          translate_table cnt_in cntm (fun cnt ->
              { evt with tag = Runtime_counter cnt })
      | _ -> evt
    with Not_mapped -> { evt with tag = Unrecognised }

(** Translate both names and tags of runtime-internal events, by [tabled_names]
    and [tabled_tags] respectively, for forward-compatibility. *)
let tabled_names_and_tags ~(actual : raw_name_table) ~(builtin : raw_name_table)
    (k : shim_callback) : shim_callback =
  tabled_names actual (tabled_tags ~actual ~builtin k)
