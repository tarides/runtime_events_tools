(lang dune 3.2)

(name runtime_events_tools)

(generate_opam_files true)

(source
 (github sadiqj/runtime_events_tools))

(authors "Author Name")

(maintainers "Maintainer Name")

(license LICENSE)

(documentation https://url/to/documentation)

(package
 (name runtime_events_tools)
 (synopsis "Tools for the Runtime_events tracing system in OCaml")
 (description "Various tools for the Runtime_events tracing system in OCaml")
 (depends ocaml dune runtime_events)
)

; See the complete stanza docs at https://dune.readthedocs.io/en/stable/dune-files.html#dune-project
