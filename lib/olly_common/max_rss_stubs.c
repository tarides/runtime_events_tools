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
 * Neither number is a peak: every platform that implements this reports
 * the RSS as it is at the sample, and the caller tracks the peak of the
 * difference.  That is forced rather than chosen — see the Linux arm.
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
 * over the consecutive matching ones as the macOS arm does. */
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
#include <sys/stat.h>
#include <unistd.h>

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
static long ring_kb(int pid, const char *ring_file) {
  struct stat st;

  /* [stat] rather than a string comparison against the region's path:
   * this resolves symlinks, so the directory olly was given need not be
   * the canonical one. */
  if (stat(ring_file, &st) != 0)
    return -1;

  uint32_t dev = (uint32_t)st.st_dev;
  uint64_t ino = (uint64_t)st.st_ino;
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

static struct rss_sample platform_sample(int pid, const char *ring_file) {
  struct rss_sample s = {0, -1};
  struct proc_taskinfo ti;

  if (ring_file)
    s.ring_kb = ring_kb(pid, ring_file);
  if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, sizeof(ti)) > 0)
    s.rss_kb = (long)(ti.pti_resident_size / 1024);
  return s;
}

#elif defined(_WIN32)

/* Take the [K32] entry points in kernel32 rather than the psapi.dll
 * forwarders of the same names, so that nothing beyond what the OCaml
 * runtime already links has to be linked.  Both toolchains key that off
 * PSAPI_VERSION, and it has to be set before <psapi.h> is first seen. */
#define PSAPI_VERSION 2

#include <stdint.h>
#include <stdlib.h>
#include <windows.h>
#include <psapi.h>

/* Size of the buffer a path is copied into.  [PATH_MAX] is what the other 
 * arms take, but here it is 260.  We decline paths longer than this.
 */
#define OLLY_PATH_MAX 4096

/* The NT path ("\Device\HarddiskVolumeN\...") of the file at [path], or
 * 0 if it could not be taken.  That is needed for [GetMappedFileNameW].
 *
 * This is the Windows counterpart of the [stat] the other arms do in order
 * to canonicalize the path. 
 *
 * Opened for no access at all, which is all the name needs, and shared
 * every way, since the child holds the file mapped and olly's own cursor
 * has it open too. */
static int nt_path_of(const wchar_t *path, wchar_t *out, DWORD out_len) {
  HANDLE h;
  DWORD n;

  h = CreateFileW(path, 0,
                  FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                  OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  if (h == INVALID_HANDLE_VALUE)
    return 0;
  n = GetFinalPathNameByHandleW(h, out, out_len,
                                FILE_NAME_NORMALIZED | VOLUME_NAME_NT);
  CloseHandle(h);
  return n > 0 && n < out_len;
}

/* Whether the region at [addr] in [proc] is backed by the file whose NT
 * path is [nt_path].
 *
 * [GetMappedFileNameW] reports how much it wrote rather than how much it
 * needed, so a name too long for the buffer comes back truncated, and
 * filling the buffer is the only sign of it.  Reject that rather than
 * compare a prefix: a ring whose path does not fit is one we decline to
 * attribute, which the caller already has to cope with.
 *
 * [CompareStringOrdinal] rather than [_wcsicmp] for case-insensitive 
 * comparison. */
static int region_backed_by(HANDLE proc, LPVOID addr, const wchar_t *nt_path) {
  wchar_t name[OLLY_PATH_MAX];
  DWORD n = GetMappedFileNameW(proc, addr, name, OLLY_PATH_MAX);

  return n > 0 && n < OLLY_PATH_MAX &&
         CompareStringOrdinal(name, -1, nt_path, -1, TRUE) == CSTR_EQUAL;
}

/* The address range of the mapping of [nt_path] in [proc], or 0 if there
 * is no such mapping.
 *
 * Walks the process's regions in ascending address order and asks each
 * mapped one which file backs it.
 *
 * One [MapViewOfFile] is one allocation, but [VirtualProtect] can split
 * it into several regions, so take the extent from the allocation base
 * that those regions share rather than naming the file again for each.
 * That also gives the view's true start, which is at or below the region
 * that happened to name it. */
static int ring_range(HANDLE proc, const wchar_t *nt_path, uintptr_t *lo,
                      uintptr_t *hi) {
  MEMORY_BASIC_INFORMATION mbi;
  uintptr_t addr = 0;
  void *view = NULL;
  int found = 0;

  *lo = 0;
  *hi = 0;

  while (VirtualQueryEx(proc, (LPCVOID)addr, &mbi, sizeof(mbi)) ==
         sizeof(mbi)) {
    uintptr_t next = (uintptr_t)mbi.BaseAddress + (uintptr_t)mbi.RegionSize;

    if (found) {
      if (mbi.AllocationBase != view)
        break; /* past the last region of the view */
      *hi = next;
    } else if (mbi.State == MEM_COMMIT && mbi.Type == MEM_MAPPED &&
               region_backed_by(proc, mbi.BaseAddress, nt_path)) {
      found = 1;
      view = mbi.AllocationBase;
      *lo = (uintptr_t)mbi.AllocationBase;
      *hi = next;
    }

    if (next <= addr)
      break; /* no progress: bail out */
    addr = next;
  }
  return found;
}

/* Resident kB of [proc]'s pages over [lo, hi), or -1 if they could not be
 * read.
 *
 * [QueryWorkingSet] hands back the process's whole working set, one entry
 * per resident page; keep the ones that fall in the range.  That is the
 * same set of pages [GetProcessMemoryInfo] returns the size of, so the
 * ring's kB are a subset of the working set's by construction and the
 * subtraction the caller performs is exact rather than an estimate across
 * two accountings, exactly as on Linux.
 *
 * [QueryWorkingSetEx] would work but it costs a query per page of the 
 * mapping, where this costs one per resident page and this can make 
 * a considerable perf difference.
 */

/* Entries to ask for beyond what is known to be needed, so that a working
 * set which grew by a little since the last sample does not cost a second
 * call. */
#define WORKING_SET_SLACK 4096

/* The buffer has to hold the whole working set at once, so a call that
 * finds it too small reports what it needed and we go again.  Bounded
 * because a process whose working set keeps growing must not be able to
 * keep us here. */
#define WORKING_SET_ATTEMPTS 8

/* Grown as needed and kept between samples: only the poller domain calls
 * in here, for one process per run, so one buffer does for the whole run
 * and there is no point freeing it before exit. 
 * 
 * NB regarding sizing the region to hold the structure: it's a number
 * plus an array. 
 * typedef struct _PSAPI_WORKING_SET_INFORMATION {
 *   ULONG_PTR               NumberOfEntries;   
 *   PSAPI_WORKING_SET_BLOCK WorkingSetInfo[1]; 
 *   PSAPI_WORKING_SET_INFORMATION; }
 * */
static PSAPI_WORKING_SET_INFORMATION *ws_buf = NULL;
static size_t ws_buf_entries = 0;

/* Make [ws_buf] hold at least [entries], leaving it as it was on failure. */
static int ws_reserve(size_t entries) {
  PSAPI_WORKING_SET_INFORMATION *grown;

  if (entries <= ws_buf_entries)
    return 1;
  grown = realloc(ws_buf, sizeof(*grown) +
                              entries * sizeof(grown->WorkingSetInfo[0]));
  if (grown == NULL)
    return 0;
  ws_buf = grown;
  ws_buf_entries = entries;
  return 1;
}

static long working_set_resident_kb(HANDLE proc, uintptr_t lo, uintptr_t hi) {
  SYSTEM_INFO si;

  GetSystemInfo(&si);

  long page_kb = (long)(si.dwPageSize / 1024);

  if (ws_buf == NULL && !ws_reserve(WORKING_SET_SLACK))
    return -1;

  for (int attempt = 0; attempt < WORKING_SET_ATTEMPTS; attempt++) {
    long present = 0;

    if (QueryWorkingSet(proc, ws_buf,
                        (DWORD)(sizeof(*ws_buf) +
                        ws_buf_entries * sizeof(ws_buf->WorkingSetInfo[0])))) {
      for (ULONG_PTR i = 0; i < ws_buf->NumberOfEntries; i++) {
        uintptr_t page = (uintptr_t)ws_buf->WorkingSetInfo[i].VirtualPage *
                         (uintptr_t)si.dwPageSize;
        if (page >= lo && page < hi)
          present++;
      }
      return present * page_kb;
    }
    if (GetLastError() != ERROR_BAD_LENGTH)
      return -1; /* the process is gone, or we may not read it */

    /* The failing call wrote [NumberOfEntries] with the count it wanted,
     * necessarily past the capacity that just failed, so each retry
     * strictly grows the buffer.  Retrying at all because the working set
     * can grow again between the call that sizes the buffer and the call
     * that fills it.  We add the slack to reduce the number of retries. */
    if (!ws_reserve((size_t)ws_buf->NumberOfEntries + WORKING_SET_SLACK))
      return -1;
  }
  return -1;
}

/* Where the ring was last seen.  Only the poller domain calls in here,
 * for one process per run.  The view is mapped once and never moves, so
 * the region walk can be done only once. */
static DWORD ring_hint_pid = 0;
static uintptr_t ring_hint_lo = 0;
static uintptr_t ring_hint_hi = 0;

static long ring_resident_kb(HANDLE proc, DWORD pid, const char *ring_file) {
  uintptr_t lo = 0, hi = 0;

  if (ring_hint_pid == pid) {
    lo = ring_hint_lo;
    hi = ring_hint_hi;
  } else {
    wchar_t wide[OLLY_PATH_MAX];
    wchar_t nt[OLLY_PATH_MAX];

    /* OCaml holds a path as UTF-8 on Windows, whatever the ANSI code page
     * is, and widens it at the Win32 boundary; do the same. */
    if (!MultiByteToWideChar(CP_UTF8, 0, ring_file, -1, wide, OLLY_PATH_MAX))
      return -1;
    if (!nt_path_of(wide, nt, OLLY_PATH_MAX))
      return -1;
    if (!ring_range(proc, nt, &lo, &hi))
      return -1;
    ring_hint_pid = pid;
    ring_hint_lo = lo;
    ring_hint_hi = hi;
  }
  return working_set_resident_kb(proc, lo, hi);
}

static struct rss_sample platform_sample(int pid, const char *ring_file) {
  struct rss_sample s = {0, -1};
  PROCESS_MEMORY_COUNTERS pmc;
  DWORD exit_code;

  /* [GetMappedFileNameW] wants PROCESS_VM_READ on top of the
   * PROCESS_QUERY_INFORMATION the other calls need. */
  HANDLE proc = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, FALSE,
                            (DWORD)pid);
  if (proc == NULL)
    return s;

  /* Sample the ring before the working set, for the reason the Linux arm
   * gives. */
  if (ring_file)
    s.ring_kb = ring_resident_kb(proc, (DWORD)pid, ring_file);
  if (GetProcessMemoryInfo(proc, &pmc, sizeof(pmc))) {
    /* PeakWorkingSetSize is a peak the kernel maintains exactly, so
     * report it where the ring cannot be taken out; where it can, report
     * the working set as it is and let the caller take the peak of the
     * difference. */
    SIZE_T bytes =
        (s.ring_kb >= 0) ? pmc.WorkingSetSize : pmc.PeakWorkingSetSize;
    s.rss_kb = (long)(bytes / 1024);
  }

  /* [GetProcessMemoryInfo] keeps answering for a process that has exited
   * while a handle to it is still open, with a residual working set and
   * the peak it reached, where everything that reads the address space
   * starts failing with ERROR_ACCESS_DENIED.  Left alone, that pair would
   * mark the whole run as not having excluded the ring.  So report "could
   * not read" instead, which is what the other arms report once the
   * process is gone, and which the caller drops.
   *
   * Checked after the numbers were read, not before: a check beforehand
   * leaves exactly the window this closes. */
  if (!GetExitCodeProcess(proc, &exit_code) || exit_code != STILL_ACTIVE) {
    s.rss_kb = 0;
    s.ring_kb = -1;
  }
  CloseHandle(proc);
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

/* Every arm but Windows, whose paths [PATH_MAX] does not bound, takes
 * that bound for the path below. */
#ifndef OLLY_PATH_MAX
#define OLLY_PATH_MAX PATH_MAX
#endif

CAMLprim value olly_rss_and_ring_kb(value v_pid, value v_ring_file) {
  CAMLparam2(v_pid, v_ring_file);
  CAMLlocal1(res);
  int pid = Int_val(v_pid);
  char ring_file[OLLY_PATH_MAX];
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
