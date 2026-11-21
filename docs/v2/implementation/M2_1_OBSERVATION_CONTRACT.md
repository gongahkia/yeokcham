# M2.1 restricted observation and manual Save contract

M2.1 observes a separately provisioned root and constructs detached content
under the prior M1a and M1b contracts. It introduces no durable root
attachment. The caller is responsible for originating and authorizing
the supplied root. The root is verified at each call, including when the
same Space is used concurrently. The qualified deployment for this tranche
is Linux x86-64, CPython 3.14.8 and the local noatime Btrfs /home mount.
The M1b SQLite allowlist is independent and remains in force.
[M2.0 native evidence](M2_0_NATIVE_QUALIFICATION.md) ·
[M1b recovery](M1B2_RECOVERY_CONTRACT.md)

## Native binding and scope

The admission anchor is the system /home mount. Open its real directory
relative to / with no symlinks, allowing that one system mount transition.
Verify Btrfs filesystem magic, subvolume root inode 256 and noatime.
Below it, open one checked raw-byte component at a time with openat2
BENEATH, NO_SYMLINKS and NO_XDEV. Verify the same device for all opened
source nodes, including Btrfs subvolumes. Pin the root and verify its
root-to-anchor directory identity chain, comparing a freshly opened chain
before success. The admitted root binding cannot drift between attempts.
The system mount and Linux ABI are trusted prerequisites. The observer
fails closed outside this profile, including unexpected ioctl results or
unavailable syscall flags. [Linux openat2](https://man7.org/linux/man-pages/man2/openat2.2.html)

Use O_PATH to pin and inspect terminal symlinks or other leaves without
opening their data. On the tested kernel, OPENAT2_REGULAR atomically limits
the data open to regular files. An independent header-built probe checked
the x86-64 syscall number 437, the 24-byte open_how layout, regular-only
flag 0x100000000, and EFTYPE refusals for FIFO and symlink. Check the
data descriptor and the parent/name against the initial pin. Read a link
via empty-path readlinkat on its pin. Check casefold on every traversed
directory, and refuse positive casefold or unavailable checks. Open
fresh independent enumeration descriptions for both passes. No ordinary
working file is opened writable or followed through a symlink.
[Linux readlinkat](https://man7.org/linux/man-pages/man2/readlink.2.html)

Reject noncanonical root components, path escapes, nested mount and bind
aliases, hardlinked regular files and repeated directory identities.
Apply parent NAME_MAX and bounds of 64 levels, 8,192 listed entries,
4 MiB aggregate raw path bytes, 64 MiB total source bytes, 16,384 distinct
detached objects and 80 MiB detached object bytes per attempt. The caller
can lower these limits. Both passes count directory names before retaining
or sorting them. Files are read in chunks of at most 64 KiB per syscall. Refuse .yeokcham and
.yeokcham-v2 namespace markers at the root, in ancestors and within the
observed tree. Refuse known backing store directory identities and an
experimental store's FORMAT and metadata.sqlite3 marker pair. Root .git
is excluded. Symlink entries may contain any representable target bytes
including references outside the root. Those targets are never traversed.

The initial ignore subset supports absent rules and regular
.yeokchamignore files containing blank/comment lines only. Such a file is
itself saved exactly. Refuse every effective or malformed rule,
nonregular ignore files and over-limit configuration before a Save.
This consciously leaves the retained OCaml glob and override syntax
unavailable. Files otherwise receive no implicit filtering.
[Retained ignore parser](../../../lib/yeokcham_snapshot/ignore.ml)

## Evidence and transaction boundary

Read a complete bounded stream, compare stat evidence before and after,
and add objects through the canonical M1a encoders. Check native identity,
kind, mode, device, inode, link count, mtime, ctime and byte length. Rewalk
with fresh enumeration, compare memberships and native stamps, and
independently re-read exact regular-file and symlink bytes for a stream
digest comparison. A matching stamp cannot substitute for bytes.
Validate the entire detached M1a closure, then finish the native recheck
and publish through the existing store only if recheck succeeds. Record a
UTC wall clock range plus monotonic elapsed duration for the observed
attempt. The range admits multiple distinct filesystem states and does
not establish later cleanliness. At most three attempts are made for
detected instability. A substituted admitted root refuses without
retargeting. Static policy failures and resource exhaustion refuse once.

Streamed objects live in a bounded, unnamed private temporary file on
the system tmpfs /tmp, outside the observation profile. Only offsets
and bounded metadata are retained in process memory. Each attempt releases
its spool on refusal, context exit or process death. M1b may retain
reachable pending objects or incomplete closure after a publication fault.
No cleanup of arbitrary files, and no GC, is introduced.

M2.1 uses an optimistic detached observation followed by the existing
workspace cursor CAS. For a manual Save the backend directory, objects
and locks identities are excluded from the observation before store access.
The store validates the workspace and expected cursor at append time. An observer holds no store lock or transaction
while reading source files. Multiple concurrent reads can overlap in the
same Space and stale writes still refuse. The M1b adapter takes its
usual locks and performs the only metadata write. The original key,
expected cursor/version and snapshot identity govern retry. The root path
and observation timestamps are per-call evidence outside the existing
durable request digest. A new key
with the same current snapshot creates no new Save. A historical repeat
can have a distinct CaptureId. An explicit resume reads the original
request and resubmits its exact arguments. It may succeed without a new
observation when the closure is already verified in the store. A pending
request whose objects are missing can be retried from a new detached
observation only if it produces the exact same snapshot. Recovery does
not invent a key or claim that the working tree was re-observed.

The old copy-out defect continues to gate application. No restore or
copy-out actuator uses this contract. [Historical diagnosis](M2_0_COPYOUT_DIAGNOSIS.md)
