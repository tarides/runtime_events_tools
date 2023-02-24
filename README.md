# Runtime events tools

A collection of observability tools around the runtime events tracing system
introduced in OCaml 5.0.

## olly

`olly latency` will report the GC tail latency profile of an OCaml executable.

```bash
$ olly latency ocamlopt.opt
GC latency profile:
#[Mean (ms):    0.34,    Stddev (ms):   0.49]
#[Min (ms):     0.01,    max (ms):      1.19]

Percentile       Latency (ms)
25.0000          0.01
50.0000          0.04
60.0000          0.04
70.0000          0.13
75.0000          0.13
80.0000          0.13
85.0000          0.13
90.0000          1.19
95.0000          1.19
96.0000          1.19
97.0000          1.19
98.0000          1.19
99.0000          1.19
99.9000          1.19
99.9900          1.19
99.9990          1.19
99.9999          1.19
100.0000         1.19
```

```bash
$ olly latency 'menhir -v --table sysver.mly' # Use quotes for commands with arguments
<snip>
GC latency profile:
#[Mean (ms):    0.03,    Stddev (ms):   0.25]
#[Min (ms):     0.00,    max (ms):      39.75]

Percentile       Latency (ms)
25.0000          0.00
50.0000          0.00
60.0000          0.00
70.0000          0.00
75.0000          0.00
80.0000          0.00
85.0000          0.00
90.0000          0.00
95.0000          0.04
96.0000          0.16
97.0000          0.26
98.0000          0.50
99.0000          0.77
99.9000          2.66
99.9900          4.48
99.9990          7.65
99.9999          39.75
100.0000         39.75
```

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

Traces in either formats can be viewed in [perfetto trace viewer](https://ui.perfetto.dev/). Chrome format trace can also be viewed in [chrome://tracing](chrome://tracing) in chromium based browsers.

![image](https://user-images.githubusercontent.com/410484/175475118-b08cbf06-a939-4edb-9336-20dfd464bb1b.png)


## Dependencies

The library depends on
[`hdr_histogram_ocaml`](https://github.com/kayceesrk/hdr_histogram_ocaml).
