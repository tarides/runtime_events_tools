#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <stdint.h>
#include <string.h>

/* Pack an FXT event header and write it directly into a Bytes.t buffer.
   All arguments are unboxed/untagged to avoid Int64 allocation.

   Layout (64 bits):
     bits  0-3:  record type (always 4 for events)
     bits  4-15: size in words
     bits 16-19: event type (0=instant, 1=counter, 2=begin, 3=end)
     bits 20-23: number of arguments
     bits 24-31: thread ref index (0 for inline)
     bits 48-63: name string ref
*/
CAMLprim value fxt_put_event_header_native(
  value v_buf, value v_pos,
  value v_size, value v_event_ty,
  value v_n_args, value v_thread_ref,
  value v_name_ref)
{
  uint8_t *buf = Bytes_val(v_buf) + Long_val(v_pos);
  uint64_t hd =
    4ULL                                    /* record type = event */
    | ((uint64_t)Long_val(v_size) << 4)
    | ((uint64_t)Long_val(v_event_ty) << 16)
    | ((uint64_t)Long_val(v_n_args) << 20)
    | ((uint64_t)Long_val(v_thread_ref) << 24)
    | ((uint64_t)Long_val(v_name_ref) << 48);
  memcpy(buf, &hd, 8);
  return Val_unit;
}

CAMLprim value fxt_put_event_header_bytecode(value *argv, int argc)
{
  (void)argc;
  return fxt_put_event_header_native(
    argv[0], argv[1], argv[2], argv[3], argv[4], argv[5], argv[6]);
}

/* Pack an FXT argument header for an int32 argument and write it.
   The int32 value is packed into the upper 32 bits of the header word.

   Layout (64 bits):
     bits  0-3:  argument type (1 = int32)
     bits  4-15: size in words
     bits 16-31: name string ref
     bits 32-63: int32 value
*/
CAMLprim value fxt_put_arg_header_i32(
  value v_buf, value v_pos,
  value v_arg_words, value v_name_ref,
  value v_value)
{
  uint8_t *buf = Bytes_val(v_buf) + Long_val(v_pos);
  uint64_t hd =
    1ULL                                      /* arg type = int32 */
    | ((uint64_t)Long_val(v_arg_words) << 4)
    | ((uint64_t)Long_val(v_name_ref) << 16)
    | ((uint64_t)(uint32_t)Long_val(v_value) << 32);
  memcpy(buf, &hd, 8);
  return Val_unit;
}

/* Pack an FXT argument header for an int64 argument and write it.

   Layout (64 bits):
     bits  0-3:  argument type (3 = int64)
     bits  4-15: size in words
     bits 16-31: name string ref
*/
CAMLprim value fxt_put_arg_header_i64(
  value v_buf, value v_pos,
  value v_arg_words, value v_name_ref)
{
  uint8_t *buf = Bytes_val(v_buf) + Long_val(v_pos);
  uint64_t hd =
    3ULL                                      /* arg type = int64 */
    | ((uint64_t)Long_val(v_arg_words) << 4)
    | ((uint64_t)Long_val(v_name_ref) << 16);
  memcpy(buf, &hd, 8);
  return Val_unit;
}
