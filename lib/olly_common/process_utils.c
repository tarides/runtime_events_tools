#include <caml/mlvalues.h>
#include <caml/memory.h>

/* [caml_win32_maperr] and [caml_uerror], for reporting a Win32 failure as the
   [Unix.Unix_error] that the rest of the Unix bindings raise. This header
   pulls in winsock2.h, which mingw wants to see before windows.h. */
#include <caml/unixsupport.h>

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

CAMLprim value olly_pid_of_handle(value v_handle) {
  CAMLparam1(v_handle);
#ifdef _WIN32
  /* Unix.create_process stores the Win32 process HANDLE in the value, so go
     through intnat rather than int: HANDLE is pointer-sized (64-bit on x64)
     while int is 32-bit. This mirrors win32unix's own stubs. */
  HANDLE handle = (HANDLE)Long_val(v_handle);
  DWORD pid = GetProcessId(handle);
  if (pid == 0) {
    caml_win32_maperr(GetLastError());
    caml_uerror("GetProcessId", Nothing);
  }
  CAMLreturn(Val_long(pid));
#else
  CAMLreturn(v_handle);
#endif
}
