(lang dune 3.2)

(name runtime_events_tools)
(version "0.5.1")
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
  hdr_histogram
  (cmdliner (>= 1.1.0))
  tracing
  (ocaml_intrinsics (>= v0.16.1))
  (menhir :with-test)
  (alcotest (and :with-test (>= 1.9.0)))))

(package
 (name runtime_events_tools_bare)
 (synopsis "Tools for the runtime events tracing system in OCaml")
 (description "Various tools for the runtime events tracing system in OCaml: minimal dependencies")
 (depends
  (ocaml (>= "5.0.0~"))
  (cmdliner (>= 1.1.0))))
