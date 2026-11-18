(* Decodes a Fuchsia trace file and prints it in a simple text format.
   Supports only the record types that olly emits.
   Resolves all table refs so that the table allocation policy does not change the output.
   Does basic bounds check on the trace and on each record.
   This is not a general purpose trace reading library but a tool for regression tests. *)

let fail fmt =
  Printf.ksprintf
    (fun msg ->
      prerr_endline ("error: " ^ msg);
      exit 1)
    fmt

(* [len] bits of [w] starting at bit [lo]. *)
let bits w lo len =
  Int64.(
    to_int (logand (shift_right_logical w lo) (sub (shift_left 1L len) 1L)))

type event = {
  ts : int64;
  pid : int64;
  tid : int64;
  kind : string;
  category : string;
  name : string;
  args : (string * string) list;
}

let decode data ~on_init ~on_event =
  let len = String.length data in
  if len mod 8 <> 0 then fail "file size %d is not a multiple of 8" len;
  let nwords = len / 8 in
  let word i = String.get_int64_le data (8 * i) in
  let strings = Hashtbl.create 16 and threads = Hashtbl.create 16 in
  let rec record pos =
    if pos < nwords then begin
      let h = word pos in
      let ty = bits h 0 4 and size = bits h 4 12 in
      if size = 0 then fail "record at word %d has size 0" pos;
      if pos + size > nwords then
        fail
          "record at word %d (type %d, %d words) extends past the end of the \
           file (%d words)"
          pos ty size nwords;
      let cursor = ref (pos + 1) in
      let read_word () =
        if !cursor >= pos + size then
          fail
            "record at word %d (type %d, %d words) extends past its declared \
             size"
            pos ty size;
        let w = word !cursor in
        incr cursor;
        w
      in
      (* Read a string of n bytes, aligned to words, at cursor *)
      let read_inline_string n =
        let str_words = (n + 7) / 8 in
        if !cursor + str_words > pos + size then
          fail
            "record at word %d (type %d, %d words) extends past its declared \
             size"
            pos ty size;
        let s = String.sub data (8 * !cursor) n in
        cursor := !cursor + str_words;
        s
      in
      (* A string reference: 0 is the empty string (read nothing), a high bit value of 1 marks an
         inline string of the given length (read at cursor), a high bit value of 0 points to a table index. *)
      let read_or_resolve_string_ref r =
        if r = 0 then ""
        else if r land 0x8000 <> 0 then
          (* Read immediate at current cursor *)
          read_inline_string (r land 0x7fff)
        else
          (* Or resolve from table *)
          match Hashtbl.find_opt strings r with
          | Some s -> s
          | None -> fail "record at word %d: unknown string ref %d" pos r
      in
      (* A thread reference: 0 indicates an inline index (read at cursor), anything else points to a table index. *)
      let read_thread r =
        if r = 0 then
          (* Read immediate *)
          let pid = read_word () in
          let tid = read_word () in
          (pid, tid)
        else
          (* Or resolve from table *)
          match Hashtbl.find_opt threads r with
          | Some thread -> thread
          | None -> fail "record at word %d: unknown thread ref %d" pos r
      in
      (match ty with
      | 0 (* Metadata *) ->
          (* We only read the magic number record, which must come
             first. Other metadata are skipped. *)
          let is_magic = bits h 16 4 = 4 && bits h 20 4 = 0 in
          if is_magic && bits h 24 32 <> 0x16547846 then
            fail "bad magic number at word %d" pos;
          if pos = 0 && not is_magic then fail "missing magic number record"
      | 1 (* Initialization record *) -> on_init (read_word ())
      | 2 (* String record *) ->
          let index = bits h 16 15 and n = bits h 32 15 in
          Hashtbl.replace strings index (read_inline_string n)
      | 3 (* Thread record *) ->
          let index = bits h 16 8 in
          let pid = read_word () in
          let tid = read_word () in
          Hashtbl.replace threads index (pid, tid)
      | 4 (* Event record *) ->
          let ety = bits h 16 4
          and nargs = bits h 20 4
          and thread_ref = bits h 24 8 in
          (* Four main fields, ts mandatory, the other three can be refs *)
          let ts = read_word () in
          let pid, tid = read_thread thread_ref in
          let category = read_or_resolve_string_ref (bits h 32 16) in
          let name = read_or_resolve_string_ref (bits h 48 16) in
          (* Then read args *)
          let rec args acc n =
            if n = 0 then List.rev acc
            else
              let start = !cursor in
              let a = read_word () in
              let aty = bits a 0 4 and asize = bits a 4 12 in
              let aname = read_or_resolve_string_ref (bits a 16 16) in
              let value =
                match aty with
                | 0 (* Null (immediate) *) -> "null"
                | 1 (* 32-bit signed integer (immediate) *) ->
                    Int32.to_string (Int64.to_int32 (Int64.shift_right a 32))
                | 2 (* 32-bit unsigned integer (immediate) *) ->
                    string_of_int (bits a 32 32)
                | 3 (* 64-bit signed integer argument (extra word) *) ->
                    Int64.to_string (read_word ())
                | 4 (* 64-bit unsigned integer argument (extra word) *) ->
                    Printf.sprintf "%Lu" (read_word ())
                | 5 (* Double-precision floating point (extra word) *) ->
                    Printf.sprintf "%h" (Int64.float_of_bits (read_word ()))
                | 6 (* String (ref or inline) *) ->
                    Printf.sprintf "%S"
                      (read_or_resolve_string_ref (bits a 32 16))
                | 9 (* Boolean (immediate) *) -> string_of_bool (bits a 32 1 = 1)
                | t ->
                    (* Pointer, Kernel object id, Blob: not emitted by olly. *)
                    fail "record at word %d: unsupported argument type %d" pos t
              in
              if !cursor - start <> asize then
                fail
                  "record at word %d: argument %S declares %d words, %d decoded"
                  pos aname asize (!cursor - start);
              args ((aname, value) :: acc) (n - 1)
          in
          let args = args [] nargs in
          (* Event type specific data *)
          let kind, extra =
            match ety with
            | 0 -> ("instant", [])
            | 1 ->
                ( "counter",
                  [ ("counter_id", Printf.sprintf "%Ld" (read_word ())) ] )
            | 2 -> ("begin", [])
            | 3 -> ("end", [])
            | 4 ->
                ("complete", [ ("end_ts", Printf.sprintf "%Ld" (read_word ())) ])
            | t ->
                (* Async and Flow: not emitted by olly *)
                fail "record at word %d: unsupported event type %d" pos t
          in
          if !cursor - pos <> size then
            fail "record at word %d: event declares %d words, %d decoded" pos
              size (!cursor - pos);
          on_event { ts; pid; tid; kind; category; name; args = args @ extra }
      | _ -> (* Kernel objects, blobs, etc.: not emitted by olly. *) ());
      record (pos + size)
    end
  in
  record 0

let print_event e =
  Printf.printf "%Ld %Ld/%Ld %s %S%s%s\n" e.ts e.pid e.tid e.kind e.name
    (if e.category = "" then "" else Printf.sprintf " category=%S" e.category)
    (String.concat ""
       (List.map (fun (k, v) -> Printf.sprintf " %s=%s" k v) e.args))

let () =
  let file =
    match Sys.argv with
    | [| _; file |] -> file
    | _ ->
        prerr_endline "usage: dump_fxt_trace FILE";
        exit 2
  in
  let data = In_channel.with_open_bin file In_channel.input_all in
  let on_init ticks = Printf.printf "ticks per second: %Ld\n" ticks in
  decode data ~on_init ~on_event:print_event
