#include <caml/mlvalues.h>
#include <caml/memory.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <signal.h>
#include <errno.h>
#endif

CAMLprim value olly_is_process_alive(value v_pid) {
  CAMLparam1(v_pid);
  int pid = Int_val(v_pid);

#ifdef _WIN32
  HANDLE proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (proc == NULL) {
    CAMLreturn(Val_false);
  }
  DWORD exit_code;
  BOOL got_exit = GetExitCodeProcess(proc, &exit_code);
  CloseHandle(proc);
  if (!got_exit || exit_code != STILL_ACTIVE) {
    CAMLreturn(Val_false);
  }
  CAMLreturn(Val_true);
#else
  int ret = kill(pid, 0);
  if (ret == 0) {
    CAMLreturn(Val_true);
  }
  /* EPERM means the process exists but we lack permission to signal it */
  if (errno == EPERM) {
    CAMLreturn(Val_true);
  }
  CAMLreturn(Val_false);
#endif
}
