### Unreleased
* Exclude the runtime events ring buffer from the max RSS reported by
  `gc-stats`, on macOS. The ring is mapped into the traced process and is
  routinely much larger than the program's own live memory, which made the
  figure useless as a memory footprint. The json output bumps to version 3
  and gains `max_rss_excludes_ring`, false on the platforms where the ring
  still cannot be told apart (#104, @ngorogiannis)
* Report lost words, not events (#126, @ngorogiannis) 
* Count explicit GC calls (`Gc.compact`, `Gc.major`, `Gc.full_major`) made by any
  domain, not just the main one (#115, @ngorogiannis)
* Check process status from a dedicated domain (#100, @ngorogiannis)
* gc-stats no longer prints a (zeroed) stats block when the run fails; it now reports only the error (#100, @ngorogiannis)
* Wait for the traced process to initialise its ring buffers (@ngorogiannis)
* Report a failure to launch or attach to the traced process as an error
  rather than an uncaught exception, and don't print empty statistics
  when nothing was collected (@ngorogiannis)
* Report lost events count only at end of run (#96, @ngorogiannis)
* Sample max RSS usage from a dedicated domain (#95, @ngorogiannis)
* Record and don't crash on latencies above histogram threshold (#93, @ngorogiannis)
* Extract common code between gc stats implementations for OCaml 5.0 and 5.3 (#93, @ngorogiannis)

### 0.5.4
* Reinstate olly latency command. (#86, @tmcgilchrist)
* Avoid overriding the user's OCAMLRUNPARAM settings. (#83, @gasche)
* Remove help subcommand, as it relies on cmdliner internals. (#81, @theAlexes)
* Fix cmdliner 2.0 compatibility. (#80, @krfantasy)
* Log path when create_cursor raises an exception. (#66, @tmcgilchrist)
* Add option to specify runtime events dir and log size. (#66, @tmcgilchrist)

### 0.5.3
* Use trace instead of tracing (#57 #59, @patricoferris @tmcgilchrist)
* Add an option to control sleep interval between calls to read_poll (#60, @tomjridge @tmcgilchrist)

### 0.5.2

* Allow olly to attach to an external process (#45, @eutro)
* Fix executable arguments when launching a process. (#55, @tmcgilchrist)
* Emit runtime counter events for tracing (#46, @kayceesrk)
* Make counters optional. (#49, @kayceesrk)
* Fix GC stats to use timestamp from events (#48,  @kayceesrk)

### 0.5.1

* Fix support on ARM64 platforms (Linux and MacOS) (#34, @tmcgilchrist)
* Remove ocamlfind dependency. (#36, @tmcgilchrist)
* Expand gc-stats help (#28, @ju-sh)

### 0.5.0

* Custom events for json (#24, @Sudha247)
* Improvements to correct gc-stats (#19, @Sudha247)
* olly trace: ingest custom events starting from OCaml 5.1 (#17, @TheLortex)

### 0.4.0

* Fix dependencies (#14, @Sudha247)
* Improve JSON output produced by olly gc-stats (#13, @punchagan)
* Mention Fuchsia format in the README (#11, @Sudha247)
* Gc subcommand (#10, @Sudha247)
* Add Fuchsia Trace Format output to olly (#6, @tomjridge)
* Added --output option to redirect olly printing (#5, @ElectreAAS)
* Added json printing option (#4, @ElectreAAS)

### 0.3

* Initial opam release

### 0.2

* Initial opam release

### 0.1

* Initial opam release
