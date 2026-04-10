#include <caml/mlvalues.h>

#ifdef _WIN32
#include <windows.h>

CAMLprim value olly_get_process_id(value v_handle) {
  HANDLE h = (HANDLE)(intnat)Long_val(v_handle);
  DWORD pid = GetProcessId(h);
  return Val_long((intnat)pid);
}

#else

CAMLprim value olly_get_process_id(value v_pid) {
  /* On Unix, create_process_env returns the actual PID */
  return v_pid;
}

#endif
