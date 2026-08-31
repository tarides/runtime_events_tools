(* Regression test for the collection counters reported by [olly gc-stats].

   The EV_EXPLICIT_GC_* phases are emitted only on the domain that called
   Gc.compact / Gc.major / Gc.full_major, so counting them on domain index 0
   alone reports zero whenever the caller is not the main domain.

   test_explicit_gc.exe makes five Gc.full_major and five Gc.compact calls
   from a spawned domain, so both counters must read 5. *)

let expected_calls = 5
let workload = "./test_explicit_gc.exe"

let olly_bin () =
  match Sys.getenv_opt "OLLY_BIN" with
  | Some p -> p
  | None -> Alcotest.fail "OLLY_BIN is not set; the dune rule should set it"

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

(* Parsing rather than scanning means this also asserts that gc-stats emits
   well-formed JSON. Yojson rejects the bare nan and inf that olly can produce
   when a metric divides by zero, so that shows up here as a parse failure
   rather than as a confusing counter mismatch. *)
let parse_json ~text =
  match Yojson.Safe.from_string text with
  | j -> j
  | exception Yojson.Json_error msg ->
      Alcotest.failf "gc-stats did not emit valid JSON (%s):@\n%s" msg text

let collection_count ~text json name =
  match Yojson.Safe.Util.(json |> member "collections" |> member name) with
  | `Int v -> v
  | `Null ->
      Alcotest.failf "no collections.%s field in gc-stats output:@\n%s" name
        text
  | other ->
      Alcotest.failf "collections.%s is not an integer, got %s" name
        (Yojson.Safe.to_string other)

(* Run [olly gc-stats --json] over the workload, capturing stdout and stderr
   so a failure can report what olly actually did. *)
let run_olly ~olly ~json_out =
  let out_file = Filename.temp_file "olly-test-stdout" ".txt" in
  let err_file = Filename.temp_file "olly-test-stderr" ".txt" in
  let opened path =
    Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600
  in
  let out_fd = opened out_file and err_fd = opened err_file in
  let pid =
    Unix.create_process olly
      [| olly; "gc-stats"; "--json"; "-o"; json_out; workload |]
      Unix.stdin out_fd err_fd
  in
  let _, status = Unix.waitpid [] pid in
  Unix.close out_fd;
  Unix.close err_fd;
  let err = read_file err_file in
  Sys.remove out_file;
  Sys.remove err_file;
  (status, err)

let status_to_string = function
  | Unix.WEXITED n -> Printf.sprintf "exited with %d" n
  | Unix.WSIGNALED n -> Printf.sprintf "killed by signal %d" n
  | Unix.WSTOPPED n -> Printf.sprintf "stopped by signal %d" n

let explicit_gc_counted () =
  let olly = olly_bin () in
  let json_out = Filename.temp_file "olly-gc-stats" ".json" in
  let status, err = run_olly ~olly ~json_out in
  (match status with
  | Unix.WEXITED 0 -> ()
  | s ->
      Alcotest.failf "%s %s@\nstderr:@\n%s" olly (status_to_string s) err);
  let text =
    match read_file json_out with
    | t -> t
    | exception Sys_error msg ->
        Alcotest.failf "could not read gc-stats json output: %s@\nstderr:@\n%s"
          msg err
  in
  Sys.remove json_out;
  let json = parse_json ~text in
  Alcotest.(check int)
    "compactions from a non-main domain" expected_calls
    (collection_count ~text json "compactions");
  Alcotest.(check int)
    "forced major collections from a non-main domain" expected_calls
    (collection_count ~text json "forced_major")

let () =
  let open Alcotest in
  run "GC counters"
    [
      ( "collections",
        [ test_case "explicit GC from a spawned domain" `Quick explicit_gc_counted ]
      );
    ]
