"""Read-only Linux x86-64 ABI used by the restricted native observer."""

import ctypes
import os

# Verified against the installed Linux UAPI headers and the M2.1 C probe.
_SYS_OPENAT2 = 437
_RESOLVE = 0x08 | 0x04  # BENEATH and NO_SYMLINKS
_NO_XDEV = 0x01
PIN = getattr(os, "O_PATH", 0) | getattr(os, "O_NOFOLLOW", 0)
DIRECTORY = getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
REGULAR = (1 << 32) | getattr(os, "O_NOFOLLOW", 0)  # OPENAT2_REGULAR
BTRFS = 0x9123683E
TMPFS = 0x01021994
WRONG_TYPE = 134  # EFTYPE, returned by OPENAT2_REGULAR on Linux x86-64
_LIBC = ctypes.CDLL(None, use_errno=True)


class _OpenHow(ctypes.Structure):
    _fields_ = [
        ("flags", ctypes.c_uint64),
        ("mode", ctypes.c_uint64),
        ("resolve", ctypes.c_uint64),
    ]


def _checked(result: int) -> int:
    if result == -1:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))
    return result


def open_at(parent: int, name: bytes, flags: int, *, system_mount: bool = False) -> int:
    syscall = _LIBC.syscall
    syscall.restype = ctypes.c_long
    how = _OpenHow(
        flags | os.O_CLOEXEC, 0, _RESOLVE if system_mount else _RESOLVE | _NO_XDEV
    )
    return _checked(
        syscall(
            ctypes.c_long(_SYS_OPENAT2),
            ctypes.c_int(parent),
            ctypes.c_char_p(name),
            ctypes.byref(how),
            ctypes.c_size_t(ctypes.sizeof(how)),
        )
    )


def filesystem(fd: int) -> int:
    # f_type is the first long of the x86-64 statfs ABI. The kernel struct
    # occupies 120 bytes on this profile. The buffer is aligned and oversized.
    result = (ctypes.c_long * 32)()
    _checked(_LIBC.fstatfs(ctypes.c_int(fd), ctypes.byref(result)))
    return int(result[0])


def casefold(fd: int) -> bool:
    import array
    import fcntl

    flags = array.array("L", [0])
    fcntl.ioctl(fd, 0x80086601, flags, True)  # FS_IOC_GETFLAGS
    return bool(flags[0] & 0x40000000)  # FS_CASEFOLD_FL
