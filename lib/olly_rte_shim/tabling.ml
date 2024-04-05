open Event

type raw_name_table = {
  lifecycle_names : string array;
  phase_names : string array;
  counter_names : string array;
}

exception Not_an_int

let lookup_name (sa : string array) (e : 'a) : string =
  if not (Obj.is_int (Obj.repr e)) then raise Not_an_int;
  let idx : int = Obj.magic e in
  sa.(idx)

let parse_from_yaml yaml_lines =
  let lc, ph, cnt = (ref None, ref None, ref None) in
  let parse_line line =
    let colon_i = String.index line ':' in
    let name = String.sub line 0 colon_i
    and constants_str =
      String.sub line (colon_i + 1) (String.length line - colon_i - 1)
    in
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

let tabled_names (table : raw_name_table) (k : shim_callback) (evt : event) :
    unit =
  k
  @@
  match evt.tag with
  | Runtime_phase ph -> { evt with name = lookup_name table.phase_names ph }
  | Runtime_counter cnt ->
      { evt with name = lookup_name table.counter_names cnt }
  | Lifecycle lc -> { evt with name = lookup_name table.lifecycle_names lc }
  | _ -> evt
