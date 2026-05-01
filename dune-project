(lang dune 3.18)

(name runtime_events_tools)
(generate_opam_files true)
(cram enable)

(source
 (github tarides/runtime_events_tools))

(authors "Sadiq Jaffer")
(maintainers "Sadiq Jaffer" "KC Sivaramakrishnan" "Sudha Parimala")
(license ISC)

(package
 (name runtime_events_tools)
 (synopsis "Tools for the runtime events tracing system in OCaml")
 (description "Various tools for the runtime events tracing system in OCaml")
 (maintenance_intent "(latest)")
 (depends
  (ocaml (>= "5.0.0~"))
  (hdr_histogram (>= "0.0.5"))
  (cmdliner (>= 2.0.0))
  (trace-fuchsia (>= 0.11))
  (trace (>= 0.11))
  (menhir :with-test)
  (ocamlformat (and :with-dev-setup (= 0.28.1)))
  (alcotest (and :with-test (>= 1.9.0)))))

(package
 (name runtime_events_tools_bare)
 (synopsis "Tools for the runtime events tracing system in OCaml")
 (description "Various tools for the runtime events tracing system in OCaml: minimal dependencies")
 (maintenance_intent "(latest)")
 (depends
  (ocaml (>= "5.0.0~"))
  (cmdliner (>= 2.0.0))))
