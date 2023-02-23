# Runtime events tools

A collection of observability tools around the runtime events tracing system
introduced in OCaml 5.0.

## olly

`olly gc-stats` will report the GC running time and GC tail latency profile of an OCaml executable.

```bash
$ olly gc-stats 'binarytrees.exe 22'
Execution times:
Wall time (s):  21.45
GC time (s):    14.33
GC overhead (% of wall time):   66.79%

GC latency profile:
#[Mean (ms):    0.92,    Stddev (ms):   1.54]
#[Min (ms):     0.00,    max (ms):      11.06]

Percentile       Latency (ms)
25.0000          0.00
50.0000          0.09
60.0000          0.42
70.0000          1.05
75.0000          1.33
80.0000          1.97
85.0000          2.22
90.0000          2.60
95.0000          3.45
96.0000          4.77
97.0000          6.52
98.0000          6.82
99.0000          7.20
99.9000          7.58
99.9900          7.86
99.9990          11.06
99.9999          11.06
100.0000         11.06
```

```bash
$ olly latency 'menhir -v --table sysver.mly' # Use quotes for commands with arguments
<snip>
Execution times:
Wall time (s):  68.51
GC time (s):    9.15
GC overhead (% of wall time):   13.35%

GC latency profile:
#[Mean (ms):    0.13,    Stddev (ms):   0.56]
#[Min (ms):     0.00,    max (ms):      42.89]

Percentile       Latency (ms)
25.0000          0.00
50.0000          0.00
60.0000          0.00
70.0000          0.00
75.0000          0.01
80.0000          0.01
85.0000          0.01
90.0000          0.32
95.0000          0.87
96.0000          1.09
97.0000          1.35
98.0000          1.74
99.0000          2.35
99.9000          5.40
99.9900          16.34
99.9990          28.31
99.9999          42.89
100.0000         42.89
```

`olly trace` will record the runtime trace log in Chrome tracing format.

```bash
$ olly trace menhir_sysver.trace 'menhir -v --table sysver.mly'
<snip>
$ ls menhir_sysver.trace
menhir_sysver.trace
```

This trace can be viewed in [perfetto trace viewer](https://ui.perfetto.dev/).

![image](https://user-images.githubusercontent.com/410484/175475118-b08cbf06-a939-4edb-9336-20dfd464bb1b.png)


## Dependencies

The library depends on
[`hdr_histogram_ocaml`](https://github.com/kayceesrk/hdr_histogram_ocaml).
