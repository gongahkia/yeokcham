/* Disposable Linux qualification probe. Built outside the source tree. */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/fs.h>
#include <linux/magic.h>
#include <linux/openat2.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <sys/vfs.h>
#include <unistd.h>

int rename_with_flags(int source, const char *name, int target,
                      const char *destination, unsigned int flags) {
  return renameat2(source, name, target, destination, flags);
}

int anchored_open(int dir, const char *path, unsigned int flags) {
  struct open_how how = {
    .flags = flags | O_CLOEXEC,
    .resolve = RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_XDEV,
  };
  return syscall(SYS_openat2, dir, path, &how, sizeof(how));
}

int directory_casefold(int fd) {
  unsigned long flags = 0;
  if (ioctl(fd, FS_IOC_GETFLAGS, &flags) < 0)
    return -1;
  return (flags & FS_CASEFOLD_FL) != 0;
}

long directory_read(int fd) {
  char buffer[8192];
  return syscall(SYS_getdents64, fd, buffer, sizeof(buffer));
}

int is_procfs(int fd) {
  struct statfs info;
  if (fstatfs(fd, &info) < 0)
    return -1;
  return info.f_type == PROC_SUPER_MAGIC;
}
