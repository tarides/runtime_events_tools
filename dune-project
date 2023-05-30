(lang dune 3.2)

(name runtime_events_tools)

(generate_opam_files true)

(source
 (github tarides/runtime_events_tools))

(authors "Sadiq Jaffer")
(maintainers "Sadiq Jaffer" "KC Sivaramakrishnan" "Sudha Parimala")
(license ISC)

(package
 (name runtime_events_tools)
 (synopsis "Tools for the runtime events tracing system in OCaml")
 (description "Various tools for the runtime events tracing system in OCaml")
 (depends
  (ocaml (>= "5.0.0~"))
  ocamlfind
  hdr_histogram
  cmdliner
  tracing
  (menhir :with-test)))
