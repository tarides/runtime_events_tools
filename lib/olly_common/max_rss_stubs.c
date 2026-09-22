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
 * Each platform arm below supplies a single [platform_sample], plain C,
 * returning both numbers.  A  platform that fails to supply [platform_sample] 
 * is a link error rather than a silently wrong number.  
 * One function rather than two because the numbers are not
 * independent on all platforms.
 *
 * Neither number is a peak: the platform that implements this reports
 * the RSS as it is at the sample, and the caller tracks the peak of the
 * difference.  That is forced rather than chosen — see the Linux arm.
 *
 * Only Linux identifies the ring so far.  On macOS the per-region
 * breakdown of proc_pidinfo(PROC_PIDREGIONPATHINFO) would locate it; on
 * FreeBSD, struct kinfo_proc has ki_rssize (RSS) and ki_size (total VM)
 * but not a heap/stack split, and libprocstat would give the per-mapping
 * breakdown needed.  Neither is attempted here, so both leave the ring
 * in.
 */

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <limits.h>
#include <string.h>

struct rss_sample {
  long rss_kb;  /* resident set size in kB, 0 if it could not be read */
  long ring_kb; /* resident kB of the ring, -1 if it could not be attributed */
};

/* Supplied by the platform arm below.  Does not touch an OCaml value,
 * and is called with the runtime lock released.  [ring_file] is NULL
 * when the caller wants the RSS only. */
static struct rss_sample platform_sample(int pid, const char *ring_file);

#if defined(__linux__)

#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

/* VmRSS and VmHWM from /proc/<pid>/status.  Either is left at 0 if its 
 * line is absent. */
static void status_rss_kb(int pid, long *rss_kb, long *hwm_kb) {
  char path[64];
  char line[256];
  FILE *f;

  *rss_kb = 0;
  *hwm_kb = 0;

  snprintf(path, sizeof(path), "/proc/%d/status", pid);
  f = fopen(path, "r");
  if (!f)
    return;
  
  bool rss_done = false;
  bool hmw_done = false;
  while ((!rss_done || !hmw_done) && fgets(line, sizeof(line), f)) {
    if (strncmp(line, "VmRSS:", 6) == 0) {
      rss_done = true;
      sscanf(line + 6, " %ld", rss_kb);
    }
    else if (strncmp(line, "VmHWM:", 6) == 0) {
      hmw_done = true;
      sscanf(line + 6, " %ld", hwm_kb);
    }
  }
  fclose(f);
}

/* The address range of the ring's mapping in [pid], or 0 if there is no
 * such mapping.
 *
 * Matching is on the inode, confirmed by either the device or the path.
 * The device alone is not enough: on btrfs, stat() reports the
 * subvolume's anonymous device while /proc/<pid>/maps prints the
 * superblock's, so the two disagree for any file outside the top-level
 * subvolume.  The path alone is not enough either, since it is gone
 * once the file has been unlinked.  
 *
 * One mmap is one VMA, but mprotect and madvise can split it, so scan
 * over the consecutive matching ones. */
static int ring_range(int pid, const char *ring_file, unsigned long *lo,
                      unsigned long *hi) {
  char path[64];
  /* The caller rejects a [ring_file] that does not fit in PATH_MAX, and
   * the fields before the pathname, plus the " (deleted)" suffix below,
   * are well under the slack: so a line naming a path that could match
   * is never split across two [fgets]. */
  char line[PATH_MAX + 128];
  char deleted[PATH_MAX + 16];
  struct stat st;
  FILE *f;
  int found = 0;

  *lo = 0;
  *hi = 0;

  if (stat(ring_file, &st) != 0)
    return 0;

  /* The kernel appends " (deleted)" to the pathname once the file has
   * been unlinked, such as when olly is attached to a process whose 
   * ring someone else removed.  Spell that form out once
   * here rather than trimming it off each line. */
  snprintf(deleted, sizeof(deleted), "%s (deleted)", ring_file);

  snprintf(path, sizeof(path), "/proc/%d/maps", pid);
  f = fopen(path, "r");
  if (!f)
    return 0;

  while (fgets(line, sizeof(line), f)) {
    unsigned long start, end;
    unsigned int maj, min;
    /* [uintmax_t] rather than [unsigned long] as on a 32-bit build with
     * _FILE_OFFSET_BITS=64 it is wider than a long. */
    uintmax_t ino;
    const char *name;
    int consumed_so_far = 0;

    line[strcspn(line, "\n")] = '\0';

    /* address, then the perms and file offset we have no use for, then
     * dev, inode, and last the pathname, which runs to the end of the line.  
     * An anonymous mapping has no pathname and [name] is then empty, matching
     * neither spelling of the ring's. 5 is the limit below as [%n] does not 
     * report a match. */
    if (sscanf(line, "%lx-%lx %*s %*s %x:%x %ju %n", &start, &end, &maj, &min,
               &ino, &consumed_so_far) < 5)
      continue;
    name = line + consumed_so_far;
    if (ino == (uintmax_t)st.st_ino &&
        (makedev(maj, min) == st.st_dev || strcmp(name, ring_file) == 0 ||
         strcmp(name, deleted) == 0)) {
      if (!found) {
        found = 1;
        *lo = start;
      }
      *hi = end;
    } else if (found)
      break; /* past the last matching mapping */
  }
  fclose(f);
  return found;
}

/* Resident kB of [pid]'s pages over [lo, hi), or -1 if they could not be
 * read.
 *
 * /proc/<pid>/pagemap reports one 8-byte entry per page, whose top bit
 * says the page is present in *this* process's page tables — the same
 * pages, from the same mm, that VmRSS counts.  So the ring's kB are a
 * subset of the RSS's by construction, and the subtraction the caller
 * performs is exact rather than an estimate across two accountings.
 * Transparent huge pages are reported as each of their constituent
 * small pages, so they need no special handling.
 *
 * Reading this needs PTRACE_MODE_READ on the target, which is the same
 * permission /proc/<pid>/maps and smaps already need; yama's
 * ptrace_scope does not narrow it, as that only governs
 * PTRACE_MODE_ATTACH.  Unprivileged readers see the present bit but a
 * zeroed page frame number, which is all this wants. */

/* Pagemap entries per read: 32kB of stack, covering 16MB of the mapping
 * per pread at a 4kB page, so a 512MB ring costs 32 of them. */
#define PAGEMAP_BATCH 4096

static long pagemap_resident_kb(int pid, unsigned long lo, unsigned long hi) {
  uint64_t entries[PAGEMAP_BATCH];
  char path[64];
  long page_size = sysconf(_SC_PAGESIZE);
  long page_kb = page_size / 1024;
  long pages = (long)((hi - lo) / page_size);
  long present = 0;
  long done = 0;
  int fd;

  snprintf(path, sizeof(path), "/proc/%d/pagemap", pid);
  fd = open(path, O_RDONLY);
  if (fd < 0)
    return -1;

  while (done < pages) {
    long want = pages - done;
    ssize_t got;

    if (want > PAGEMAP_BATCH)
      want = PAGEMAP_BATCH;
    got = pread(fd, entries, (size_t)want * sizeof(entries[0]),
                (off_t)((lo / page_size) + done) * (off_t)sizeof(entries[0]));
    if (got <= 0) { /* the process is gone, or we may not read it */
      close(fd);
      return -1;
    }
    got /= (ssize_t)sizeof(entries[0]);
    for (ssize_t i = 0; i < got; i++)
      if (entries[i] >> 63)
        present++;
    done += got;
  }
  close(fd);
  return present * page_kb;
}

/* Where the ring was last seen.  Only the poller domain calls in here,
 * for one process per run.  The mapping is made once and never moves, 
 * so the /proc/<pid>/maps scan can be done only once. */
static int ring_hint_pid = 0;
static unsigned long ring_hint_lo = 0;
static unsigned long ring_hint_hi = 0;

static long ring_resident_kb(int pid, const char *ring_file) {
  unsigned long lo = 0, hi = 0;

  if (ring_hint_pid == pid) {
    lo = ring_hint_lo;
    hi = ring_hint_hi;
  } else if (ring_range(pid, ring_file, &lo, &hi)) {
    ring_hint_pid = pid;
    ring_hint_lo = lo;
    ring_hint_hi = hi;
  } else
    return -1;

  return pagemap_resident_kb(pid, lo, hi);
}

static struct rss_sample platform_sample(int pid, const char *ring_file) {
  struct rss_sample s = {0, -1};
  long rss_kb, hwm_kb;

  /* Sample the ring before the RSS: the ring only grows, so what skew there is
   * between two reads that are not one atomic sample lands on the side
   * of over-reporting the program's own footprint rather than under. */
  if (ring_file)
    s.ring_kb = ring_resident_kb(pid, ring_file);
  status_rss_kb(pid, &rss_kb, &hwm_kb);

  /* VmHWM is a peak the kernel maintains exactly.  So where the ring can 
   * be attributed, report VmRSS and let the caller take the peak of the 
   * difference. Otherwise, return VmHWM which is more accurate as it's not 
   * a sampled value. */
  s.rss_kb = (s.ring_kb >= 0) ? rss_kb : hwm_kb;
  return s;
}

#elif defined(__APPLE__)

#include <libproc.h>
#include <sys/proc_info.h>

/* proc_pidinfo(PROC_PIDREGIONPATHINFO) reports the per-region breakdown
 * that would locate the ring; until it is used, the ring is left in. */
static struct rss_sample platform_sample(int pid, const char *ring_file) {
  struct rss_sample s = {0, -1};
  struct proc_taskinfo ti;

  (void)ring_file;
  if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, sizeof(ti)) > 0)
    s.rss_kb = (long)(ti.pti_resident_size / 1024);
  return s;
}

#elif defined(__FreeBSD__)

#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/user.h>
#include <unistd.h>

/* kinfo_proc carries no per-mapping breakdown; libprocstat would be
 * needed to locate the ring, so the ring is left in. */
static struct rss_sample platform_sample(int pid, const char *ring_file) {
  struct rss_sample s = {0, -1};
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
  struct kinfo_proc kp;
  size_t len = sizeof(kp);

  (void)ring_file;
  if (sysctl(mib, 4, &kp, &len, NULL, 0) == 0)
    s.rss_kb = (long)kp.ki_rssize * getpagesize() / 1024;
  return s;
}

#else

static struct rss_sample platform_sample(int pid, const char *ring_file) {
  struct rss_sample s = {0, -1};

  (void)pid;
  (void)ring_file;
  return s;
}

#endif

CAMLprim value olly_rss_and_ring_kb(value v_pid, value v_ring_file) {
  CAMLparam2(v_pid, v_ring_file);
  CAMLlocal1(res);
  int pid = Int_val(v_pid);
  char ring_file[PATH_MAX];
  const char *ring_arg = NULL;
  struct rss_sample s;
  size_t len;

  /* Copy the path out of the OCaml heap: nothing between
   * [caml_enter_blocking_section] and [caml_leave_blocking_section] may
   * touch an OCaml value, since the GC can run and move it while we
   * are blocked. */
  len = caml_string_length(v_ring_file);
  if (len >= sizeof(ring_file))
    len = 0; /* too long to be a path we could have created */
  memcpy(ring_file, String_val(v_ring_file), len);
  ring_file[len] = '\0';

  /* Counting the ring's resident pages means walking its mapping, which
   * takes up to ~1ms.  Held across that, the runtime lock would keep this
   * domain from servicing STW requests, and a minor GC on the domain
   * draining the ring would stall behind it. */
  caml_enter_blocking_section();
  ring_arg = ring_file[0] != '\0' ? ring_file : NULL;
  s = platform_sample(pid, ring_arg);
  caml_leave_blocking_section();

  res = caml_alloc_small(2, 0);
  Field(res, 0) = Val_long(s.rss_kb);
  Field(res, 1) = Val_long(s.ring_kb);
  CAMLreturn(res);
}
