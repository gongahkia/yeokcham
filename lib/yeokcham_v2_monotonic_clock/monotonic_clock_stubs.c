#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

#include <caml/fail.h>
#include <caml/mlvalues.h>

CAMLprim value yeokcham_monotonic_milliseconds(value unit)
{
  struct timespec timestamp;
  int64_t milliseconds;
  (void)unit;

  if (clock_gettime(CLOCK_MONOTONIC, &timestamp) != 0) {
    caml_failwith(strerror(errno));
  }

  if (timestamp.tv_sec > Max_long / 1000) {
    caml_failwith("monotonic clock exceeds OCaml integer range");
  }

  milliseconds = ((int64_t)timestamp.tv_sec * 1000)
                 + ((int64_t)timestamp.tv_nsec / 1000000);
  return Val_long(milliseconds);
}
