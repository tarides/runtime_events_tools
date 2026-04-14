module B = Fxt_buf

type thread = {
  pid : int64;
  tid : int64;
}

type strings = {
  mutable str_next : int;
  str_table : string option array;
  str_index : (string, int) Hashtbl.t;
}

type threads = {
  mutable thr_next : int;
  thr_table : (int64 * int64) option array;
  thr_index : (int64 * int64, int) Hashtbl.t;
}

type t = {
  oc : out_channel;
  buf : B.t;
  strings : strings;
  threads : threads;
}

(* Number of 8-byte words for a padded string *)
let[@inline] str_word_len s = (String.length s + 7) asr 3

(* String references -------------------------------------------------------- *)

type str_ref = Str_ref of int | Str_inline of string

let str_ref_lookup strings s =
  match s with
  | "" -> Str_ref 0
  | _ ->
    (match Hashtbl.find_opt strings.str_index s with
     | Some i -> Str_ref i
     | None ->
       if String.length s > 32000 then invalid_arg "FXT: string too long";
       Str_inline s)

let[@inline] str_ref_encode = function
  | Str_ref x -> x
  | Str_inline s -> 0x8000 lor String.length s

let[@inline] str_ref_words = function
  | Str_ref _ -> 0
  | Str_inline s -> str_word_len s

let str_ref_write buf = function
  | Str_ref _ -> ()
  | Str_inline s -> B.put_string_padded buf s

let str_ref_add t s =
  if s <> "" && not (Hashtbl.mem t.strings.str_index s) then begin
    let st = t.strings in
    let i = st.str_next in
    st.str_next <- if i = 0x7fff then 1 else i + 1;
    Option.iter (Hashtbl.remove st.str_index) st.str_table.(i);
    st.str_table.(i) <- Some s;
    Hashtbl.replace st.str_index s i;
    let str_words = str_word_len s in
    let words = str_words + 1 in
    let data =
      Int64.(logor (of_int i) (shift_left (of_int (String.length s)) 16))
    in
    B.put_64 t.buf
      Int64.(logor (of_int 2) (logor (shift_left (of_int words) 4)
                                 (shift_left data 16)));
    B.put_string_padded t.buf s
  end

(* Thread references -------------------------------------------------------- *)

type thr_ref = Thr_ref of int | Thr_inline of { pid : int64; tid : int64 }

let thr_ref_lookup threads v =
  match Hashtbl.find_opt threads.thr_index (v.pid, v.tid) with
  | Some i -> Thr_ref i
  | None -> Thr_inline { pid = v.pid; tid = v.tid }

let[@inline] thr_ref_encode = function
  | Thr_ref x -> x
  | Thr_inline _ -> 0

let[@inline] thr_ref_size = function
  | Thr_ref _ -> 0
  | Thr_inline _ -> 2

let thr_ref_write buf = function
  | Thr_ref _ -> ()
  | Thr_inline { pid; tid } ->
    B.put_64 buf pid;
    B.put_64 buf tid

let thr_ref_add t v =
  let key = (v.pid, v.tid) in
  if not (Hashtbl.mem t.threads.thr_index key) then begin
    let th = t.threads in
    let i = th.thr_next in
    th.thr_next <- if i = 0xff then 1 else i + 1;
    Option.iter (Hashtbl.remove th.thr_index) th.thr_table.(i);
    th.thr_table.(i) <- Some key;
    Hashtbl.replace th.thr_index key i;
    B.put_64 t.buf
      Int64.(logor (of_int 3)
               (logor (shift_left (of_int 3) 4)
                  (shift_left (of_int i) 16)));
    B.put_64 t.buf v.pid;
    B.put_64 t.buf v.tid
  end

(* Writer ------------------------------------------------------------------- *)

let buf_size = 65536
let max_event_bytes = 33000

let ensure_space t =
  if B.available t.buf < max_event_bytes then
    B.flush t.buf t.oc

let create oc =
  let buf = B.create buf_size in
  let strings = {
    str_next = 1;
    str_table = Array.make 0x8000 None;
    str_index = Hashtbl.create 200;
  } in
  let threads = {
    thr_next = 1;
    thr_table = Array.make 0x100 None;
    thr_index = Hashtbl.create 20;
  } in
  let t = { oc; buf; strings; threads } in
  (* Magic record *)
  B.put_64 buf 0x0016547846040010L;
  (* Initialization record: 1 tick = 1ns *)
  B.put_64 buf 0x0000000000140010L;
  B.put_64 buf 1_000_000_000L;
  t

let close t =
  B.flush t.buf t.oc;
  close_out t.oc

let[@inline] is_i32 (i : int) : bool = Int32.(to_int (of_int i) = i)

(* Write an event header via C stub (zero Int64 boxing), then advance pos *)
let[@inline] write_event_header buf ~words ~event_ty ~n_args ~thread_ref ~name_ref =
  let pos = B.pos buf in
  B.put_event_header (B.bytes buf) pos
    words event_ty n_args thread_ref name_ref;
  B.advance buf 8

(* Emit a span or instant event. Zero-allocation when name and thread are
   already interned (the common case after the first event). *)
let emit_event t ~event_ty ~thread ~name ~ts =
  ensure_space t;
  str_ref_add t name;
  thr_ref_add t thread;
  let name_ref = str_ref_lookup t.strings name in
  let thread_ref = thr_ref_lookup t.threads thread in
  let words = 2 + thr_ref_size thread_ref + str_ref_words name_ref in
  write_event_header t.buf ~words ~event_ty ~n_args:0
    ~thread_ref:(thr_ref_encode thread_ref)
    ~name_ref:(str_ref_encode name_ref);
  B.put_64 t.buf ts;
  thr_ref_write t.buf thread_ref;
  str_ref_write t.buf name_ref

let duration_begin t ~thread ~name ~ts =
  emit_event t ~event_ty:2 ~thread ~name ~ts

let duration_end t ~thread ~name ~ts =
  emit_event t ~event_ty:3 ~thread ~name ~ts

let instant t ~thread ~name ~ts =
  emit_event t ~event_ty:0 ~thread ~name ~ts

(* Counter events include one int argument named "v" and a counter_id word. *)
let counter t ~thread ~name ~ts ~value =
  ensure_space t;
  str_ref_add t name;
  str_ref_add t "v";
  thr_ref_add t thread;
  let name_ref = str_ref_lookup t.strings name in
  let v_ref = str_ref_lookup t.strings "v" in
  let thread_ref = thr_ref_lookup t.threads thread in
  let arg_words = (if is_i32 value then 1 else 2) + str_ref_words v_ref in
  let words =
    2 + thr_ref_size thread_ref + str_ref_words name_ref
    + arg_words + 1 (* counter_id *)
  in
  write_event_header t.buf ~words ~event_ty:1 ~n_args:1
    ~thread_ref:(thr_ref_encode thread_ref)
    ~name_ref:(str_ref_encode name_ref);
  B.put_64 t.buf ts;
  thr_ref_write t.buf thread_ref;
  str_ref_write t.buf name_ref;
  (* Argument "v" via C stub *)
  let arg_pos = B.pos t.buf in
  let v_enc = str_ref_encode v_ref in
  if is_i32 value then begin
    B.put_arg_header_i32 (B.bytes t.buf) arg_pos arg_words v_enc value;
    B.advance t.buf 8;
    str_ref_write t.buf v_ref
  end else begin
    B.put_arg_header_i64 (B.bytes t.buf) arg_pos arg_words v_enc;
    B.advance t.buf 8;
    str_ref_write t.buf v_ref;
    B.put_64 t.buf (Int64.of_int value)
  end;
  (* Counter ID *)
  B.put_64 t.buf 0L
