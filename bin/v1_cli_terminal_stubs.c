#define _XOPEN_SOURCE 700
#include <caml/mlvalues.h>

#ifndef _WIN32
#include <locale.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <wchar.h>
#endif

CAMLprim value yeokcham_cli_terminal_width(value unit) {
  (void)unit;
#ifndef _WIN32
  struct winsize size;
  if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 0)
    return Val_int(size.ws_col);
#endif
  return Val_int(0);
}

CAMLprim value yeokcham_cli_character_width(value character) {
#ifndef _WIN32
  /* use a thread-local UTF-8 locale without changing the application's locale. */
  locale_t locale = newlocale(LC_CTYPE_MASK, "C.UTF-8", (locale_t)0);
  if (!locale)
    locale = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", (locale_t)0);
  if (locale) {
    locale_t previous = uselocale(locale);
    int width = wcwidth((wchar_t)Int_val(character));
    uselocale(previous);
    freelocale(locale);
    if (width >= 0) return Val_int(width);
  }
#endif
  return Val_int(Int_val(character) < 128 ? 1 : 2);
}
