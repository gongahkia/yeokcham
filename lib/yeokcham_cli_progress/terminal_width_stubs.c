#include <sys/ioctl.h>
#include <unistd.h>

#include <caml/mlvalues.h>

CAMLprim value yeokcham_cli_progress_stderr_columns(value unit)
{
  struct winsize size;
  (void)unit;

  if (ioctl(STDERR_FILENO, TIOCGWINSZ, &size) != 0 || size.ws_col == 0) {
    return Val_int(0);
  }

  return Val_int(size.ws_col);
}
