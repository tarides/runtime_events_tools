# Runtime events tools

A collection of observability tools around the runtime events tracing system
introduced in OCaml 5.0.

## olly

olly provides a number of sub-commands.

### gc-stats

`olly gc-stats` will report the GC running time and GC tail latency profile of an OCaml executable.

| Metric             | Description                                                                                                                                   |
|--------------------|-----------------------------------------------------------------------------------------------------------------------------------------------|
| Wall time          | Real execution time of the program                                                                                                            |
| CPU time           | Total CPU time across all domains                                                                                                             |
| GC time            | Total time spent by the program performing garbage collection (major and minor)                                                               |
| GC overhead        | Percentage of time taken up by GC against the total execution time                                                                            |
| GC time per domain | Time spent by every domain performing garbage collection (major and minor cycles). Domains are reported with their domain ID (e.g. `Domain0`) |
| GC latency profile | Mean, standard deviation and percentile latency profile of GC events.                                                                         |


```bash
$ olly gc-stats 'binarytrees.exe 19' # Use quotes for commands with arguments
Execution times:
Wall time (s):	2.01
CPU time (s):	5.73
GC time (s):	3.15
GC overhead (% of CPU time):	55.00%

GC time per domain (s):
Domain0: 	1.15
Domain1: 	0.99
Domain2: 	1.01

GC latency profile:
#[Mean (ms):	0.88,	 Stddev (ms):	1.67]
#[Min (ms):	0.00,	 max (ms):	13.21]

Percentile 	 Latency (ms)
25.0000 	 0.01
50.0000 	 0.04
60.0000 	 0.13
70.0000 	 0.45
75.0000 	 0.79
80.0000 	 1.53
85.0000 	 2.46
90.0000 	 3.46
95.0000 	 4.38
96.0000 	 5.07
97.0000 	 5.87
98.0000 	 6.45
99.0000 	 7.08
99.9000 	 11.20
99.9900 	 13.21
99.9990 	 13.21
99.9999 	 13.21
100.0000 	 13.21
```

```bash
$ olly gc-stats 'menhir -v --table sysver.mly' # Use quotes for commands with arguments
<snip>
Execution times:
Wall time (s):	60.88
CPU time (s):	60.88
GC time (s):	7.30
GC overhead (% of CPU time):	11.99%

GC time per domain (s):
Domain0: 	7.30

GC latency profile:
#[Mean (ms):	0.10,	 Stddev (ms):	0.43]
#[Min (ms):	0.00,	 max (ms):	39.16]

Percentile 	 Latency (ms)
25.0000 	 0.00
50.0000 	 0.00
60.0000 	 0.00
70.0000 	 0.00
75.0000 	 0.00
80.0000 	 0.00
85.0000 	 0.01
90.0000 	 0.26
95.0000 	 0.69
96.0000 	 0.88
97.0000 	 1.04
98.0000 	 1.30
99.0000 	 1.91
99.9000 	 4.56
99.9900 	 8.31
99.9990 	 9.83
99.9999 	 39.16
100.0000 	 39.16
```

### trace

`olly trace` will record the runtime trace log in 
[Fuchsia trace format](https://fuchsia.dev/fuchsia-src/reference/tracing/trace-format) 
or
[Chrome tracing format](https://docs.google.com/document/d/1CvAClvFfyA5R-PhYUmn5OOQtYMH4h6I0nSsKchNAySU/preview)
. Format of the trace file can be specified with the
`--format` option. The default is Fuchsia trace format.

```bash
$ olly trace --format=fuchsia menhir_sysver.trace 'menhir -v --table sysver.mly' # Fuchsia trace format
<snip>
$ ls menhir_sysver.trace
menhir_sysver.trace

$ olly trace --format=json menhir_sysver.trace 'menhir -v --table sysver.mly' # Chrome tracing format
<snip>
$ ls menhir_sysver.trace
menhir_sysver.trace
```

Traces in either formats can be viewed in [perfetto trace viewer](https://ui.perfetto.dev/). Chrome format trace can also be viewed in `chrome://tracing` in chromium-based browsers.

![image](https://user-images.githubusercontent.com/410484/175475118-b08cbf06-a939-4edb-9336-20dfd464bb1b.png)


## Dependencies

The library depends on
[`hdr_histogram_ocaml`](https://github.com/ocaml-multicore/hdr_histogram_ocaml).
