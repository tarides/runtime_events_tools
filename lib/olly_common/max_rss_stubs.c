/*
 * max_rss_stubs.c — sample a running process's RSS, and the part of it
 * that is due to the runtime_events ring buffer.
 *
 * The ring is a file-backed MAP_SHARED mapping of <dir>/<pid>.events in
 * the traced process, so its resident pages are charged to that
 * process's RSS.  The ring is routinely far larger than the program's
 * own live memory (a 512MB ring against a 3MB live set is not unusual),
 * which made the reported peak RSS useless as a memory footprint.  So
 * we report the ring's own resident size alongside the RSS and let the
 * caller subtract it.
 *
 * [olly_rss_and_ring_kb] returns a pair (rss_kb, ring_kb), where
 * [ring_kb] is -1 if the ring's contribution could not be determined —
 * either because this platform has no implementation, or because the
 * mapping could not be found.  Passing an empty [ring_file] asks for
 * the RSS only.
 *
 * Each platform arm below supplies [platform_rss_kb] and
 * [platform_ring_kb], both plain C.  The single [olly_rss_and_ring_kb]
 * that calls them lives outside the #if chain, so the FFI mechanics —
 * root registration, copying the path out of the OCaml heap, releasing
 * the runtime lock — are written once, and an arm that fails to supply
 * either function is a build failure rather than a silently wrong
 * number.
 *
 * Only macOS identifies the ring so far.  On Linux we read VmHWM, a
 * peak computed by the kernel, which cannot be decomposed against the
 * *current* per-mapping Rss: that /proc/<pid>/smaps reports; that needs
 * a different approach and is not attempted here.
 *
 * On Linux the same /proc/<pid>/status file exposes additional fields
 * that would be valuable for GC sweep / compiler-comparison benchmarks,
 * and which would cost no extra syscalls — just scanning more lines in
 * the same read pass:
 *
 *   Field     What it measures                   Useful for
 *   -------   --------------------------------   ----------------------------------
 *   VmRSS     Current RSS at sample time         Memory trajectory over time
 *   VmData    Heap + anonymous mappings           Directly reflects GC heap sizing;
 *                                                 changes with minor-heap size (s)
 *                                                 and space overhead (o) parameters
 *   VmStk     Stack size                          Stack-heavy benchmarks: deep
 *                                                 recursion, effects/continuations
 *                                                 (multicore-effects suite), and
 *                                                 comparing stack segment handling
 *                                                 across compiler versions
 *   VmPeak    Peak virtual address space           Total address space pressure
 *                                                 including mmap'd regions and the
 *                                                 runtime events ring buffer
 *   VmSize    Current virtual address space       Same as VmPeak but instantaneous
 *   Threads   Thread count                        Sanity check for multicore
 *                                                 benchmarks (confirms domain count)
 *
 * On FreeBSD, struct kinfo_proc has ki_rssize (RSS) and ki_size (total
 * VM) but not a heap/stack split; libprocstat would give the per-mapping
 * breakdown needed to locate the ring.
 */

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <limits.h>
#include <string.h>

/* Supplied by the platform arm below.  Neither touches an OCaml value,
 * and both are called with the runtime lock released.
 *
 * [platform_rss_kb] returns the process's resident set size in kB, or 0
 * if it could not be read.  [platform_ring_kb] returns the resident kB
 * of the ring buffer mapped from [ring_file], or -1 where the platform
 * cannot attribute it. */
static long platform_rss_kb(int pid);
static long platform_ring_kb(int pid, const char *ring_file);

#if defined(__linux__)

#include <stdio.h>

static long platform_rss_kb(int pid) {
  char path[64];
  char line[256];
  long vmhwm = 0;
  FILE *f;

  snprintf(path, sizeof(path), "/proc/%d/status", pid);
  f = fopen(path, "r");
  if (!f)
    return 0;

  while (fgets(line, sizeof(line), f)) {
    if (strncmp(line, "VmHWM:", 6) == 0) {
      sscanf(line + 6, " %ld", &vmhwm);
      break;
    }
  }
  fclose(f);
  return vmhwm;
}

/* VmHWM is a peak maintained by the kernel, and the per-mapping Rss: in
 * /proc/<pid>/smaps is a current figure; subtracting one from the other
 * is not sound.  Leave the ring in. */
static long platform_ring_kb(int pid, const char *ring_file) {
  (void)pid;
  (void)ring_file;
  return -1;
}

#elif defined(__APPLE__)

#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/stat.h>
#include <unistd.h>

static long platform_rss_kb(int pid) {
  struct proc_taskinfo ti;

  if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, sizeof(ti)) <= 0)
    return 0;
  return (long)(ti.pti_resident_size / 1024);
}

/* Resident kB of the VM regions of [pid] that are backed by the vnode
 * (dev, ino) and lie at or above [from], or -1 if there is no such
 * region.  On success [*found_at] is the address of the first one.
 *
 * Regions are matched on their backing vnode rather than on
 * prp_vip.vip_path, which holds only the "tail end" of long paths and
 * need not be spelled the way the caller spelled it.  A large mapping
 * can be split across several adjacent regions, so sum over all of the
 * consecutive matching ones. */
static long vnode_resident_kb(int pid, uint64_t from, uint32_t dev,
                              uint64_t ino, uint64_t *found_at) {
  long page_kb = getpagesize() / 1024;
  uint64_t addr = from;
  long total = 0;
  int found = 0;

  for (;;) {
    struct proc_regionwithpathinfo r;
    uint64_t next;

    if (proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, addr, &r, sizeof(r)) <= 0)
      break; /* past the last region, or the process is gone */
    if (r.prp_vip.vip_vi.vi_stat.vst_dev == dev &&
        r.prp_vip.vip_vi.vi_stat.vst_ino == ino) {
      if (!found) {
        found = 1;
        *found_at = r.prp_prinfo.pri_address;
      }
      total += (long)r.prp_prinfo.pri_pages_resident * page_kb;
    } else if (found)
      break; /* past the last matching region */

    next = r.prp_prinfo.pri_address + r.prp_prinfo.pri_size;
    if (next <= addr)
      break; /* no progress: bail out rather than spin */

    addr = next;
  }
  return found ? total : -1;
}

/* Where the ring was last seen.  Only the poller domain calls in here,
 * for one process per run. */
static int ring_hint_pid = 0;
static uint64_t ring_hint_addr = 0;

/* Counting a region's resident pages costs the kernel a walk of its page
 * list (~0.35ms for a 256MB-resident ring), and reaching the region at
 * all costs a walk of every region below it (~1ms).  The ring's mapping
 * never moves, so remember where it was and start there next time,
 * falling back to the full walk if it is no longer at that address. */
static long ring_resident_kb(int pid, uint32_t dev, uint64_t ino) {
  uint64_t hint = (ring_hint_pid == pid) ? ring_hint_addr : 0;
  uint64_t found_at = 0;
  long total = -1;

  if (hint != 0)
    total = vnode_resident_kb(pid, hint, dev, ino, &found_at);
  if (total < 0)
    total = vnode_resident_kb(pid, 0, dev, ino, &found_at);

  if (total >= 0) {
    ring_hint_pid = pid;
    ring_hint_addr = found_at;
  }
  return total;
}

static long platform_ring_kb(int pid, const char *ring_file) {
  struct stat st;

  /* [stat] rather than a string comparison against the region's path:
   * this resolves symlinks, so the directory olly was given need not be
   * the canonical one. */
  if (stat(ring_file, &st) != 0)
    return -1;
  return ring_resident_kb(pid, (uint32_t)st.st_dev, (uint64_t)st.st_ino);
}

#elif defined(__FreeBSD__)

#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/user.h>
#include <unistd.h>

static long platform_rss_kb(int pid) {
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
  struct kinfo_proc kp;
  size_t len = sizeof(kp);

  if (sysctl(mib, 4, &kp, &len, NULL, 0) != 0)
    return 0;
  return (long)kp.ki_rssize * getpagesize() / 1024;
}

/* kinfo_proc carries no per-mapping breakdown; libprocstat would be
 * needed to locate the ring. */
static long platform_ring_kb(int pid, const char *ring_file) {
  (void)pid;
  (void)ring_file;
  return -1;
}

#else

static long platform_rss_kb(int pid) {
  (void)pid;
  return 0;
}

static long platform_ring_kb(int pid, const char *ring_file) {
  (void)pid;
  (void)ring_file;
  return -1;
}

#endif

/* Build the (rss_kb, ring_kb) result.  Must be called with the runtime
 * lock held.
 *
 * Both fields are immediate, so nothing between the allocation and the
 * stores can collect and [res] cannot move.  The root is registered
 * regardless: giving this tuple a boxed field later would mean
 * allocating that field, which could move [res] out from under us, and
 * the resulting heap corruption would be neither local nor obvious. */
static value rss_and_ring(long rss_kb, long ring_kb) {
  CAMLparam0();
  CAMLlocal1(res);

  res = caml_alloc_small(2, 0);
  Field(res, 0) = Val_long(rss_kb);
  Field(res, 1) = Val_long(ring_kb);
  CAMLreturn(res);
}

CAMLprim value olly_rss_and_ring_kb(value v_pid, value v_ring_file) {
  CAMLparam2(v_pid, v_ring_file);
  int pid = Int_val(v_pid);
  char ring_file[PATH_MAX];
  size_t len;
  long rss_kb;
  long ring_kb = -1;

  /* Copy the path out of the OCaml heap: nothing between
   * [caml_enter_blocking_section] and [caml_leave_blocking_section] may
   * touch an OCaml value, since the GC can run — and move it — while we
   * are blocked. */
  len = caml_string_length(v_ring_file);
  if (len >= sizeof(ring_file))
    len = 0; /* too long to be a path we could have created */
  memcpy(ring_file, String_val(v_ring_file), len);
  ring_file[len] = '\0';

  /* The macOS region walk takes up to ~1ms.  Held across that, the
   * runtime lock would keep this domain from servicing STW requests, and
   * a minor GC on the domain draining the ring would stall behind it —
   * which is how ring words get lost. */
  caml_enter_blocking_section();
  rss_kb = platform_rss_kb(pid);
  if (ring_file[0] != '\0')
    ring_kb = platform_ring_kb(pid, ring_file);
  caml_leave_blocking_section();

  CAMLreturn(rss_and_ring(rss_kb, ring_kb));
}
