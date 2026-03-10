#include <caml/mlvalues.h>

#if defined(__linux__)

#include <stdio.h>
#include <string.h>

CAMLprim value olly_get_rss_kb(value v_pid) {
  int pid = Int_val(v_pid);
  char path[64];
  char line[256];
  long vmhwm = 0;
  FILE *f;

  snprintf(path, sizeof(path), "/proc/%d/status", pid);
  f = fopen(path, "r");
  if (!f)
    return Val_long(0);

  while (fgets(line, sizeof(line), f)) {
    if (strncmp(line, "VmHWM:", 6) == 0) {
      sscanf(line + 6, " %ld", &vmhwm);
      break;
    }
  }
  fclose(f);
  return Val_long(vmhwm);
}

#elif defined(__APPLE__)

#include <libproc.h>
#include <sys/proc_info.h>

CAMLprim value olly_get_rss_kb(value v_pid) {
  int pid = Int_val(v_pid);
  struct proc_taskinfo ti;
  int ret = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, sizeof(ti));
  if (ret <= 0)
    return Val_long(0);
  return Val_long(ti.pti_resident_size / 1024);
}

#elif defined(__FreeBSD__)

#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/user.h>
#include <unistd.h>

CAMLprim value olly_get_rss_kb(value v_pid) {
  int pid = Int_val(v_pid);
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
  struct kinfo_proc kp;
  size_t len = sizeof(kp);
  if (sysctl(mib, 4, &kp, &len, NULL, 0) != 0)
    return Val_long(0);
  return Val_long((long)kp.ki_rssize * getpagesize() / 1024);
}

#else

CAMLprim value olly_get_rss_kb(value v_pid) {
  (void)v_pid;
  return Val_long(0);
}

#endif
