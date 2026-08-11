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
Wall time (s):	0.52
CPU time (s):	1.47
GC time (s):	0.62
GC overhead (% of CPU time):	41.98%
Max RSS (kB):	65840

Per domain stats:
Domain   Wall   GC(s)   GC(%)  
0        0.52   0.24    45.12  
1        0.49   0.21    42.19  
2        0.46   0.17    38.17  

GC latency profile:
#[Mean (ms):	0.23,	 Stddev (ms):	0.53]
#[Min (ms):	0.00,	 max (ms):	4.71]

Percentile 	 Latency (ms)
25.0000 	 0.00
50.0000 	 0.01
60.0000 	 0.01
70.0000 	 0.05
75.0000 	 0.13
80.0000 	 0.24
85.0000 	 0.55
90.0000 	 0.89
95.0000 	 1.29
96.0000 	 1.39
97.0000 	 1.51
98.0000 	 2.11
99.0000 	 2.74
99.9000 	 3.57
99.9900 	 4.71
99.9990 	 4.71
99.9999 	 4.71
100.0000 	 4.71

GC allocations (in words): 
Total heap:	 295711855
Minor heap:	 301109826
Major heap:	 45017730
Promoted words:	 50415701 (16.74%)

Per domain stats: 
Domain   Total      Minor       Promoted   Major      Promoted(%)  
0        99721155   101879432   18727340   16569063   18.38        
1        97590020   99615197    16072386   14047209   16.13        
2        98400680   99615197    15615975   14401458   15.68        
Minor Gen: 461 collections
Major Gen: 40 collections 0 forced collections
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

If olly does not read a domain's ring buffer fast enough then some events will be lost, which is reported as `[ring_id=6] Lost 1584944 events`. If this occurs the results from olly *may* be inaccurate. There are several ways to fix this:

1. Use `--freq` option to make olly read the ring buffer more frequently.
2. Set `OCAMLRUNPARAM=e=20` to increase the size of the ring buffer.
3. If events are being lost at startup, consider adding a brief sleep to the beginning of your program so olly has time to attach to it.

## Dependencies

The library depends on [`hdr_histogram_ocaml`](https://github.com/ocaml-multicore/hdr_histogram_ocaml).
