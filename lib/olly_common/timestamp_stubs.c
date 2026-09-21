#define CAML_INTERNALS
#include "caml/alloc.h"
#include "caml/mlvalues.h"
#include "caml/osdeps.h"
#include "caml/version.h"

#if OCAML_VERSION < 50400

CAMLprim uint64_t caml_ml_runtime_current_timestamp_unboxed(value unit) {
  return caml_time_counter();
}

CAMLprim value caml_ml_runtime_current_timestamp(value unit) {
  return caml_copy_int64(caml_time_counter());
}

#endif
