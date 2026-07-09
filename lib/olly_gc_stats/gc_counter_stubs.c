/* Native consumer for `olly gc-stats`.
 *
 * Profiling showed that for allocation-heavy / bursty workloads the dominant
 * cost of consuming runtime_events is the per-event C->OCaml callback dispatch
 * (plus an Int64 box for the timestamp), not the work done in the callbacks.
 * That overhead is paid once per event and is what causes the consumer to fall
 * behind and drop events.
 *
 * This stub owns a single cursor over the monitored process's .events file and
 * processes *every* event type (counters, runtime begin/end, lifecycle) in C,
 * accumulating into plain C state. The OCaml side no longer registers any
 * runtime_events callbacks and does not poll its own cursor; it just drives
 * [poll] and reads the accumulated results out via the getters below at the
 * end of the run.
 *
 * Latency percentiles reuse the same hdr_histogram C library that the OCaml
 * `hdr_histogram` binding links, so the numbers are identical to the previous
 * implementation. Only the few hdr functions used are declared here, avoiding
 * a build-time dependency on the package's header.
 *
 * A single monitored process at a time => single global cursor + state keeps
 * the surface minimal. Unix-only for now (char_os == char). */

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/misc.h>
#include <caml/mlvalues.h>
#include <caml/runtime_events_consumer.h>
#include <caml/version.h>

/* --- hdr_histogram C API (provided by libhdr_histogram.a, already linked via
   the OCaml hdr_histogram binding that olly depends on) --- */
struct hdr_histogram;
extern int hdr_init(int64_t lowest_discernible_value,
                    int64_t highest_trackable_value, int significant_figures,
                    struct hdr_histogram **result);
extern bool hdr_record_value(struct hdr_histogram *h, int64_t value);
extern int64_t hdr_value_at_percentile(const struct hdr_histogram *h,
                                        double percentile);
extern int64_t hdr_min(const struct hdr_histogram *h);
extern int64_t hdr_max(const struct hdr_histogram *h);
extern double hdr_mean(const struct hdr_histogram *h);
extern double hdr_stddev(const struct hdr_histogram *h);

#define OLLY_MAX_DOMAINS 128
/* Must match the OCaml histogram parameters. */
#define LOWEST_DISCERNIBLE_VALUE 10LL
#define HIGHEST_TRACKABLE_VALUE 10000000000LL

static struct caml_runtime_events_cursor *olly_cursor = NULL;
static struct hdr_histogram *olly_hist = NULL;

/* allocation counters (words) */
static int64_t olly_minor_words[OLLY_MAX_DOMAINS];
static int64_t olly_promoted_words[OLLY_MAX_DOMAINS];
static int64_t olly_major_words[OLLY_MAX_DOMAINS];

/* GC pause time per domain (ns), and the in-progress GC phase being timed */
static int64_t olly_gc_times[OLLY_MAX_DOMAINS];
static int olly_inprogress_phase[OLLY_MAX_DOMAINS]; /* -1 = none */
static int64_t olly_inprogress_ts[OLLY_MAX_DOMAINS];

/* collection counts (domain 0 only, matching the OCaml implementation) */
static int64_t olly_minor_colls;
static int64_t olly_major_colls;
static int64_t olly_forced_major_colls;
static int64_t olly_compactions;

/* wall clock + per-domain elapsed time (seconds) */
static double olly_wall_start;
static double olly_wall_end;
static double olly_domain_elapsed[OLLY_MAX_DOMAINS];

/* GC pauses too large for the histogram are summarised here */
static int64_t olly_outliers_count;
static int64_t olly_outliers_total;
static int64_t olly_outliers_max;

static int64_t olly_lost = 0;

/* Diagnostics: per-ring counts of events consumed and lost, to determine
   whether the load is spread across rings (so sharding the consumer across
   threads would help) or concentrated, and how large the drain deficit is. */
static int64_t olly_event_counts[OLLY_MAX_DOMAINS];
static int64_t olly_lost_per_domain[OLLY_MAX_DOMAINS];

static const int64_t bytes_per_word = (int64_t)sizeof(value);

static inline bool is_gc_phase(ev_runtime_phase phase) {
  return phase == EV_MAJOR || phase == EV_STW_LEADER ||
         phase == EV_INTERRUPT_REMOTE;
}

/* The per-event callbacks and the latency recorder are intentionally NOT
   static: as global symbols they show up by name in sampling profilers (local
   symbols are often folded into the neighbouring global symbol, hiding the hot
   path). They keep the olly_ prefix to avoid clashing with runtime symbols. */

/* Record [latency] (ns) into the histogram, or fold it into the outlier
   summary if it is out of range. Mirrors record_latency in OCaml:
   hdr_record_value returns false for out-of-range values; non-positive
   latencies are spurious and ignored. */
void olly_record_latency(int64_t latency) {
  if (!hdr_record_value(olly_hist, latency) &&
      latency > HIGHEST_TRACKABLE_VALUE) {
    olly_outliers_count++;
    olly_outliers_total += latency;
    if (latency > olly_outliers_max) olly_outliers_max = latency;
  }
}

int olly_on_counter(int domain_id, void *data, uint64_t ts,
                    ev_runtime_counter counter, uint64_t val) {
  (void)data;
  (void)ts;
  if (domain_id < 0 || domain_id >= OLLY_MAX_DOMAINS) return 1;
  olly_event_counts[domain_id]++;
  switch (counter) {
    case EV_C_MINOR_PROMOTED:
      olly_promoted_words[domain_id] += (int64_t)(val / bytes_per_word);
      break;
    case EV_C_MINOR_ALLOCATED:
      olly_minor_words[domain_id] += (int64_t)(val / bytes_per_word);
      break;
#if OCAML_VERSION >= 50300
    /* EV_C_MAJOR_ALLOCATED_WORDS was added in OCaml 5.3; on 5.0-5.2 major
       allocations are not reported (the OCaml 5.0 implementation did not track
       them either) and olly_major_words stays zero. */
    case EV_C_MAJOR_ALLOCATED_WORDS:
      olly_major_words[domain_id] += (int64_t)val;
      break;
#endif
    default:
      break;
  }
  return 1;
}

int olly_on_begin(int domain_id, void *data, uint64_t ts,
                  ev_runtime_phase phase) {
  (void)data;
  if (domain_id < 0 || domain_id >= OLLY_MAX_DOMAINS) return 1;
  olly_event_counts[domain_id]++;
  if (domain_id == 0) {
    switch (phase) {
      case EV_EXPLICIT_GC_COMPACT:
        olly_compactions++;
        break;
      case EV_MINOR:
        olly_minor_colls++;
        break;
      /* EV_MAJOR corresponds to any GC collection; the stop-the-world phase at
         the end of a major cycle is the specific one we count. */
      case EV_MAJOR_GC_STW:
        olly_major_colls++;
        break;
      case EV_EXPLICIT_GC_MAJOR:
      case EV_EXPLICIT_GC_FULL_MAJOR:
        olly_forced_major_colls++;
        break;
      default:
        break;
    }
  }
  if (is_gc_phase(phase) && olly_inprogress_phase[domain_id] < 0) {
    olly_inprogress_phase[domain_id] = (int)phase;
    olly_inprogress_ts[domain_id] = (int64_t)ts;
  }
  return 1;
}

int olly_on_end(int domain_id, void *data, uint64_t ts,
                ev_runtime_phase phase) {
  (void)data;
  if (domain_id < 0 || domain_id >= OLLY_MAX_DOMAINS) return 1;
  olly_event_counts[domain_id]++;
  if (olly_inprogress_phase[domain_id] == (int)phase) {
    olly_inprogress_phase[domain_id] = -1;
    int64_t latency = (int64_t)ts - olly_inprogress_ts[domain_id];
    olly_record_latency(latency);
    olly_gc_times[domain_id] += latency;
  }
  return 1;
}

int olly_on_lifecycle(int domain_id, void *data, int64_t ts_ns,
                      ev_lifecycle lifecycle, int64_t lc_data) {
  (void)data;
  (void)lc_data;
  if (domain_id < 0 || domain_id >= OLLY_MAX_DOMAINS) return 1;
  olly_event_counts[domain_id]++;
  double ts = (double)ts_ns / 1000000000.0;
  switch (lifecycle) {
    case EV_RING_START:
      olly_wall_start = ts;
      olly_domain_elapsed[domain_id] = ts;
      break;
    case EV_RING_STOP:
      olly_wall_end = ts;
      olly_domain_elapsed[domain_id] = ts - olly_domain_elapsed[domain_id];
      break;
    case EV_DOMAIN_SPAWN:
      olly_domain_elapsed[domain_id] = ts;
      break;
    case EV_DOMAIN_TERMINATE:
      olly_domain_elapsed[domain_id] = ts - olly_domain_elapsed[domain_id];
      break;
    default:
      break;
  }
  return 1;
}

int olly_on_lost(int domain_id, void *data, int lost_words) {
  (void)data;
  olly_lost += (int64_t)lost_words;
  if (domain_id >= 0 && domain_id < OLLY_MAX_DOMAINS)
    olly_lost_per_domain[domain_id] += (int64_t)lost_words;
  return 1;
}

/* start : path -> pid -> int (runtime_events_error, 0 = success) */
CAMLprim value olly_gc_counter_start(value v_path, value v_pid) {
  CAMLparam2(v_path, v_pid);
  memset(olly_minor_words, 0, sizeof olly_minor_words);
  memset(olly_promoted_words, 0, sizeof olly_promoted_words);
  memset(olly_major_words, 0, sizeof olly_major_words);
  memset(olly_gc_times, 0, sizeof olly_gc_times);
  memset(olly_domain_elapsed, 0, sizeof olly_domain_elapsed);
  for (int i = 0; i < OLLY_MAX_DOMAINS; i++) olly_inprogress_phase[i] = -1;
  olly_minor_colls = olly_major_colls = olly_forced_major_colls =
      olly_compactions = 0;
  olly_wall_start = olly_wall_end = 0.0;
  olly_outliers_count = olly_outliers_total = olly_outliers_max = 0;
  olly_lost = 0;
  memset(olly_event_counts, 0, sizeof olly_event_counts);
  memset(olly_lost_per_domain, 0, sizeof olly_lost_per_domain);

  if (olly_hist == NULL &&
      hdr_init(LOWEST_DISCERNIBLE_VALUE, HIGHEST_TRACKABLE_VALUE, 3,
               &olly_hist) != 0)
    CAMLreturn(Val_int(E_ALLOC_FAIL));

  runtime_events_error res = caml_runtime_events_create_cursor(
      (const char_os *)String_val(v_path), Int_val(v_pid), &olly_cursor);
  if (res == E_SUCCESS) {
    caml_runtime_events_set_runtime_counter(olly_cursor, olly_on_counter);
    caml_runtime_events_set_runtime_begin(olly_cursor, olly_on_begin);
    caml_runtime_events_set_runtime_end(olly_cursor, olly_on_end);
    caml_runtime_events_set_lifecycle(olly_cursor, olly_on_lifecycle);
    caml_runtime_events_set_lost_events(olly_cursor, olly_on_lost);
  } else {
    olly_cursor = NULL;
  }
  CAMLreturn(Val_int(res));
}

/* poll : unit -> int (events consumed). Drains everything available. */
CAMLprim value olly_gc_counter_poll(value unit) {
  CAMLparam1(unit);
  uintnat consumed = 0;
  if (olly_cursor != NULL)
    caml_runtime_events_read_poll(olly_cursor, NULL, 0, &consumed);
  CAMLreturn(Val_long(consumed));
}

CAMLprim value olly_gc_counter_stop(value unit) {
  CAMLparam1(unit);
  if (olly_cursor != NULL) {
    caml_runtime_events_free_cursor(olly_cursor);
    olly_cursor = NULL;
  }
  CAMLreturn(Val_unit);
}

/* --- getters (read once at end of run) --- */

CAMLprim value olly_gc_counter_minor_words(value d) {
  return Val_long(olly_minor_words[Int_val(d)]);
}
CAMLprim value olly_gc_counter_promoted_words(value d) {
  return Val_long(olly_promoted_words[Int_val(d)]);
}
CAMLprim value olly_gc_counter_major_words(value d) {
  return Val_long(olly_major_words[Int_val(d)]);
}
CAMLprim value olly_gc_counter_gc_time(value d) {
  return Val_long(olly_gc_times[Int_val(d)]);
}
CAMLprim value olly_gc_counter_domain_elapsed(value d) {
  return caml_copy_double(olly_domain_elapsed[Int_val(d)]);
}
CAMLprim value olly_gc_counter_wall_start(value unit) {
  (void)unit;
  return caml_copy_double(olly_wall_start);
}
CAMLprim value olly_gc_counter_wall_end(value unit) {
  (void)unit;
  return caml_copy_double(olly_wall_end);
}
CAMLprim value olly_gc_counter_minor_collections(value unit) {
  (void)unit;
  return Val_long(olly_minor_colls);
}
CAMLprim value olly_gc_counter_major_collections(value unit) {
  (void)unit;
  return Val_long(olly_major_colls);
}
CAMLprim value olly_gc_counter_forced_major_collections(value unit) {
  (void)unit;
  return Val_long(olly_forced_major_colls);
}
CAMLprim value olly_gc_counter_compactions(value unit) {
  (void)unit;
  return Val_long(olly_compactions);
}
CAMLprim value olly_gc_counter_hist_mean(value unit) {
  (void)unit;
  return caml_copy_double(olly_hist == NULL ? 0.0 : hdr_mean(olly_hist));
}
CAMLprim value olly_gc_counter_hist_stddev(value unit) {
  (void)unit;
  return caml_copy_double(olly_hist == NULL ? 0.0 : hdr_stddev(olly_hist));
}
CAMLprim value olly_gc_counter_hist_min(value unit) {
  (void)unit;
  return Val_long(olly_hist == NULL ? 0 : hdr_min(olly_hist));
}
CAMLprim value olly_gc_counter_hist_max(value unit) {
  (void)unit;
  return Val_long(olly_hist == NULL ? 0 : hdr_max(olly_hist));
}
CAMLprim value olly_gc_counter_hist_value_at_percentile(value p) {
  return Val_long(olly_hist == NULL
                      ? 0
                      : hdr_value_at_percentile(olly_hist, Double_val(p)));
}
CAMLprim value olly_gc_counter_outliers_count(value unit) {
  (void)unit;
  return Val_long(olly_outliers_count);
}
CAMLprim value olly_gc_counter_outliers_total(value unit) {
  (void)unit;
  return Val_long(olly_outliers_total);
}
CAMLprim value olly_gc_counter_outliers_max(value unit) {
  (void)unit;
  return Val_long(olly_outliers_max);
}
CAMLprim value olly_gc_counter_lost_events(value unit) {
  (void)unit;
  return Val_long(olly_lost);
}
CAMLprim value olly_gc_counter_events(value d) {
  return Val_long(olly_event_counts[Int_val(d)]);
}
CAMLprim value olly_gc_counter_lost_per_domain(value d) {
  return Val_long(olly_lost_per_domain[Int_val(d)]);
}
