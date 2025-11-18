### Unreleased
* Add option to specify runtime events dir and log size. (#66 @tmcgilchrist)

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
