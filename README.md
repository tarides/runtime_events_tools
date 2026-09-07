# Runtime events tools

A collection of observability tools around the [runtime events tracing](https://ocaml.org/manual/runtime-tracing.html) system introduced in OCaml 5.0.

To install runtime_events_tools:

```
opam install runtime_events_tools
```

The main tool is called `olly`, it provides a number of sub-commands for gathering runtime events and reporting. Run `olly --help` to see all available options.

### Reporting Garbage Collection Statistics

Running `olly gc-stats` will report the GC running time and GC tail latency profile of an OCaml executable.

| Metric                 | Description                                                                        |
|------------------------|------------------------------------------------------------------------------------|
| Wall time              | Real execution time of the program                                                 |
| CPU time               | Total CPU time across all domains                                                  |
| GC time                | Total time spent by the program performing garbage collection (major and minor)    |
| GC overhead            | Percentage of time taken up by GC against the total execution time                 |
| Max RSS                | Peak resident set size of the traced process, sampled during execution             |
| GC time per domain     | Time spent by every domain performing garbage collection (major and minor cycles). |
| GC latency profile     | Mean, standard deviation and percentile latency profile of GC events.              |
| GC allocations         | Words allocated and promoted over the run, in total and per domain                 |
| Collections            | Counts of minor and major collections, forced collections and compactions          |

Note: all times are wall-clock and so include time spent blocking.

Note: the allocation figures are cumulative totals for the whole run, not heap
sizes. `Minor heap` is every word allocated in the minor heap, `Major heap` is
every word that reached the major heap whether by promotion or by direct
allocation, and `Total heap` is the two combined with the promoted words counted
once. Values that a given OCaml version cannot report are `null` in the JSON
output and omitted from the human-readable output.

```bash
$ olly gc-stats './test_gc_stats.exe 18' # Use quotes for commands with arguments
Execution times:
Wall time (s):	0.54
CPU time (s):	1.52
GC time (s):	0.65
GC overhead (% of CPU time):	42.91%
Max RSS (kB):	64448

Per domain time:
Domain   Wall   GC(s)   GC(%)  
0        0.54   0.24    43.79  
1        0.48   0.20    40.98  
2        0.51   0.22    43.80  

GC latency profile:
#[Mean (ms):	0.24,	 Stddev (ms):	0.53]
#[Min (ms):	0.00,	 max (ms):	4.14]

Percentile 	 Latency (ms)
25.0000 	 0.00
50.0000 	 0.01
60.0000 	 0.02
70.0000 	 0.05
75.0000 	 0.14
80.0000 	 0.28
85.0000 	 0.58
90.0000 	 0.98
95.0000 	 1.31
96.0000 	 1.38
97.0000 	 1.56
98.0000 	 2.25
99.0000 	 2.72
99.9000 	 3.35
99.9900 	 4.14
99.9990 	 4.14
99.9999 	 4.14
100.0000 	 4.14

GC allocations (in words): 
Total heap:	 296241054
Minor heap:	 301205191
Major heap:	 46112581
Promoted words:	 51076718 (16.96%)

Per domain allocations:
Domain   Total       Minor       Promoted   Major      Promoted(%)  
0        100222337   101974797   17913651   16161191   17.57        
1        97996796    99615197    16575682   14957281   16.64        
2        98021921    99615197    16587385   14994109   16.65        
Minor Gen: 467 collections
Major Gen: 41 collections 0 forced collections
Compactions: 0
```

Note: if the GC pauses for longer than the histogram's highest bucket can record, the output will include a line of the form
#[Beyond histogram (> 17179869 ms): 5 events, mean (ms): 19000000, max (ms): 20000000]
In this case, mean and standard deviation results only apply to the histogram contents and do not include the outlier values. The max result does.

### Tracing a program

`olly trace` will record the runtime trace log in
[Fuchsia trace format](https://fuchsia.dev/fuchsia-src/reference/tracing/trace-format)
or
[Chrome tracing format](https://docs.google.com/document/d/1CvAClvFfyA5R-PhYUmn5OOQtYMH4h6I0nSsKchNAySU/preview)
. The trace format can be specified with the `--format` option, with the default being Fuchsia trace format.

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

## Missed events

If olly does not read a domain's ring buffer fast enough then some events will be lost, which is reported as `[ring_id=6] Lost 1584944 ring buffer words, stats not reliable`. If this occurs the results from olly *may* be inaccurate. There are several ways to fix this:

1. Use `--freq` option to make olly read the ring buffer more frequently.
2. Set `OCAMLRUNPARAM=e=20` to increase the size of the ring buffer.
3. If events are being lost at startup, consider adding a brief sleep to the beginning of your program so olly has time to attach to it.

## Dependencies

The library depends on [`hdr_histogram_ocaml`](https://github.com/ocaml-multicore/hdr_histogram_ocaml).
