#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/unixsupport.h>

#ifndef _WIN32
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <sys/stat.h>
#include <unistd.h>

static value fingerprint(const struct stat *s) {
#ifdef __APPLE__
  struct timespec mt = s->st_mtimespec, ct = s->st_ctimespec;
#else
  struct timespec mt = s->st_mtim, ct = s->st_ctim;
#endif
  /* atime changes while reading; nanosecond mtime/ctime detect same-size writes. */
  return caml_alloc_sprintf("%ju:%ju:%ju:%ju:%jd:%jd:%ld:%jd:%ld",
    (uintmax_t)s->st_dev, (uintmax_t)s->st_ino, (uintmax_t)s->st_mode,
    (uintmax_t)s->st_nlink, (intmax_t)s->st_size,
    (intmax_t)mt.tv_sec, mt.tv_nsec, (intmax_t)ct.tv_sec, ct.tv_nsec);
}

CAMLprim value yeokcham_scan_open_at(value parent, value name, value directory) {
  CAMLparam3(parent, name, directory);
  caml_unix_check_path(name, "openat");
  int base = Is_block(parent) ? Int_val(Field(parent, 0)) : AT_FDCWD;
  int flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK;
  if (Bool_val(directory)) flags |= O_DIRECTORY;
  int fd = openat(base, String_val(name), flags);
  if (fd < 0) caml_uerror("openat", name);
  CAMLreturn(Val_int(fd));
}

CAMLprim value yeokcham_scan_inspect_at(value parent, value name) {
  CAMLparam2(parent, name);
  CAMLlocal2(result, stamp);
  caml_unix_check_path(name, "fstatat");
  struct stat s;
  if (fstatat(Int_val(parent), String_val(name), &s, AT_SYMLINK_NOFOLLOW) < 0)
    caml_uerror("fstatat", name);
  int kind;
  if (S_ISREG(s.st_mode)) kind = 0;
  else if (S_ISDIR(s.st_mode)) kind = 1;
  else if (S_ISLNK(s.st_mode)) kind = 2;
  else if (S_ISFIFO(s.st_mode)) kind = 3;
  else if (S_ISSOCK(s.st_mode)) kind = 4;
  else if (S_ISCHR(s.st_mode)) kind = 5;
  else if (S_ISBLK(s.st_mode)) kind = 6;
  else caml_failwith("unsupported filesystem node kind");
  stamp = fingerprint(&s);
  result = caml_alloc_tuple(2);
  Store_field(result, 0, Val_int(kind));
  Store_field(result, 1, stamp);
  CAMLreturn(result);
}

CAMLprim value yeokcham_scan_fingerprint(value fd) {
  CAMLparam1(fd);
  struct stat s;
  if (fstat(Int_val(fd), &s) < 0) caml_uerror("fstat", Nothing);
  CAMLreturn(fingerprint(&s));
}

CAMLprim value yeokcham_scan_readlink_at(value parent, value name) {
  CAMLparam2(parent, name);
  CAMLlocal1(buffer);
  caml_unix_check_path(name, "readlinkat");
  mlsize_t capacity = 256;
  for (;;) {
    buffer = caml_alloc_string(capacity);
    ssize_t count = readlinkat(Int_val(parent), String_val(name),
                              (char *)Bytes_val(buffer), capacity);
    if (count < 0) caml_uerror("readlinkat", name);
    if ((mlsize_t)count < capacity)
      CAMLreturn(caml_alloc_initialized_string(count, String_val(buffer)));
    if (capacity > Bsize_wsize(Max_wosize) / 2) caml_failwith("symlink target too large");
    capacity *= 2;
  }
}

static void directory_finalize(value handle) {
  DIR **directory = (DIR **)Data_custom_val(handle);
  if (*directory) { closedir(*directory); *directory = NULL; }
}

static struct custom_operations directory_operations = {
  "yeokcham.scan-directory.v1", directory_finalize,
  custom_compare_default, custom_hash_default, custom_serialize_default,
  custom_deserialize_default, custom_compare_ext_default, custom_fixed_length_default
};

CAMLprim value yeokcham_scan_open_directory(value fd) {
  CAMLparam1(fd);
  CAMLlocal1(handle);
  handle = caml_alloc_custom(&directory_operations, sizeof(DIR *), 0, 1);
  *((DIR **)Data_custom_val(handle)) = NULL;
  /* a new open description gives every enumeration an independent position. */
  int copy = openat(Int_val(fd), ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (copy < 0) caml_uerror("openat-directory", Nothing);
  DIR *directory = fdopendir(copy);
  if (!directory) {
    int saved = errno;
    close(copy);
    caml_unix_error(saved, "fdopendir", Nothing);
  }
  *((DIR **)Data_custom_val(handle)) = directory;
  CAMLreturn(handle);
}

CAMLprim value yeokcham_scan_read_directory(value handle) {
  CAMLparam1(handle);
  DIR *directory = *((DIR **)Data_custom_val(handle));
  if (!directory) caml_invalid_argument("closed capture directory");
  errno = 0;
  struct dirent *entry = readdir(directory);
  if (!entry) {
    if (errno) caml_uerror("readdir", Nothing);
    caml_raise_end_of_file();
  }
  CAMLreturn(caml_copy_string(entry->d_name));
}

CAMLprim value yeokcham_scan_close_directory(value handle) {
  CAMLparam1(handle);
  directory_finalize(handle);
  CAMLreturn(Val_unit);
}
#else
/* A Windows adapter must supply the same no-follow observation contract. */
#define UNAVAILABLE(name) CAMLprim value name(value a) { \
  (void)a; caml_failwith("native no-follow capture is unavailable"); }
UNAVAILABLE(yeokcham_scan_fingerprint)
UNAVAILABLE(yeokcham_scan_open_directory)
UNAVAILABLE(yeokcham_scan_read_directory)
UNAVAILABLE(yeokcham_scan_close_directory)
CAMLprim value yeokcham_scan_open_at(value a, value b, value c) {
  (void)a; (void)b; (void)c; caml_failwith("native no-follow capture is unavailable");
}
CAMLprim value yeokcham_scan_inspect_at(value a, value b) {
  (void)a; (void)b; caml_failwith("native no-follow capture is unavailable");
}
CAMLprim value yeokcham_scan_readlink_at(value a, value b) {
  (void)a; (void)b; caml_failwith("native no-follow capture is unavailable");
}
#endif
