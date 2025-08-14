# Runtime events tools

A collection of observability tools around the [runtime events tracing](https://ocaml.org/manual/runtime-tracing.html) system introduced in OCaml 5.0.

To install runtime_events_tools:

```
opam install runtime_events_tools
```

The main tool is called `olly`, it provides a number of sub-commands for gathering runtime events and reporting. Run `olly --help` to see all available options.

### Reporting Garbage Collection Statistics

Running `olly gc-stats` will report the GC running time and GC tail latency profile of an OCaml executable.

| Metric             | Description                                                                                                                                   |
|--------------------|-----------------------------------------------------------------------------------------------------------------------------------------------|
| Wall time          | Real execution time of the program                                                                                                            |
| CPU time           | Total CPU time across all domains                                                                                                             |
| GC time            | Total time spent by the program performing garbage collection (major and minor)                                                               |
| GC overhead        | Percentage of time taken up by GC against the total execution time                                                                            |
| GC time per domain | Time spent by every domain performing garbage collection (major and minor cycles). Domains are reported with their domain ID (e.g. `Domain0`) |
| GC latency profile | Mean, standard deviation and percentile latency profile of GC events.                                                                         |

Note: all times are wall-clock and so include time spent blocking.

```bash
$ olly gc-stats 'EXECUTABLE' # Use quotes for commands with arguments
Execution times:
Wall time (s):  114.15
CPU time (s):   1012.84
GC time (s):    173.08
GC overhead (% of CPU time):    17.09%

Per domain stats:
Domain   Wall(s)         GC(s)   GC(%)
0        114.15          11.52   10.10
1        112.19          20.00   17.83
2        112.19          20.64   18.40
3        112.21          20.20   18.01
4        112.19          20.33   18.12
5        112.28          19.91   17.73
6        112.20          20.32   18.11
7        112.87          19.75   17.49
8        112.57          20.41   18.13

GC latency profile:
#[Mean (ms):    4.95,    Stddev (ms):   5.58]
#[Min (ms):     0.00,    max (ms):      72.55]

Percentile       Latency (ms)
25.0000          0.05
50.0000          4.66
60.0000          5.51
70.0000          6.38
75.0000          6.89
80.0000          7.54
85.0000          8.54
90.0000          10.56
95.0000          14.58
96.0000          16.27
97.0000          18.14
98.0000          21.10
99.0000          26.62
99.9000          47.19
99.9900          66.98
99.9990          72.55
99.9999          72.55
100.0000         72.55
```

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
