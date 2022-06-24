A collection of tools around the runtime events tracing system introduced in
OCaml 5.0.

## ocaml-runtime-tracer

```
Usage:
$ olly <trace_filename> <executable> <args...> 
```

`ocaml-runtime-tracer` will record the runtime tracelog to `<trace_filename>`
of the given `<executable>` and `<args>`.

## Dependencies

The library depends on
[`hdr_histogram_ocaml`](https://github.com/kayceesrk/hdr_histogram_ocaml).
