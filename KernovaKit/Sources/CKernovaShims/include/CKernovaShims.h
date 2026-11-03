#ifndef CKERNOVASHIMS_H
#define CKERNOVASHIMS_H

#include <stddef.h>
#include <stdint.h>

#if defined(__aarch64__) || defined(_M_ARM64) || defined(__x86_64__) || defined(_M_X64)
/// Advances a CRC32C register over `count` bytes with the CPU's CRC32C
/// instructions: the Armv8 CRC32 extension on arm64 (mandatory from Armv8.1),
/// SSE4.2 on x86_64. The register is the raw state, neither pre- nor
/// post-inverted.
uint32_t kernova_crc32c_hardware_update(uint32_t crc, const uint8_t *bytes, size_t count);
#endif

/// Nanoseconds on a monotonic clock that keeps counting while the machine
/// sleeps: Darwin `CLOCK_MONOTONIC`, Linux `CLOCK_BOOTTIME`, Windows
/// `QueryInterruptTimePrecise`. The origin is arbitrary.
uint64_t kernova_monotonic_nanoseconds(void);

#if defined(__linux__)
/// Creates a non-blocking, close-on-exec `AF_VSOCK` stream socket and starts
/// connecting it to `port` at `cid`. Returns the descriptor, with
/// `*in_progress` set to 1 when the connect is still under way (`EINPROGRESS`)
/// and 0 when it completed; returns -1 with `errno` set, holding nothing open,
/// when creating the socket or starting the connect failed.
int kernova_vsock_connect(uint32_t cid, uint32_t port, int *in_progress);

/// `openat2(2)`, which neither glibc nor musl wraps: opens `name` in
/// `directory` with `flags` and `mode`, and when `resolve_beneath` is nonzero
/// with `RESOLVE_BENEATH`, so the kernel refuses any resolution that leaves
/// `directory`. Returns the descriptor, or -1 with `errno` set.
int kernova_openat2(int directory, const char *name, int flags, uint32_t mode, int resolve_beneath);

/// `renameat2(2)` with `RENAME_NOREPLACE`, through the system call, since
/// musl does not declare the wrapper. Returns 0, or -1 with `errno` set.
int kernova_rename_exclusive(int directory, const char *name, int new_directory, const char *new_name);

/// `fallocate(2)` with `FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE`: frees
/// `length` bytes at `offset` in the open file `descriptor`, which then read
/// as zeros. Returns 0, or -1 with `errno` set.
int kernova_punch_hole(int descriptor, int64_t offset, int64_t length);

/// `fsetxattr(2)`, creating or replacing the attribute. Returns 0, or -1 with
/// `errno` set.
int kernova_set_xattr(int descriptor, const char *name, const void *value, size_t size);

/// `flistxattr(2)`: the open file's attribute names, each ending in NUL,
/// into `names`, or with `size` 0 the bytes they take. Returns that count,
/// or -1 with `errno` set.
long kernova_list_xattr(int descriptor, char *names, size_t size);

/// `fgetxattr(2)`: the attribute's value into `value`, or with `size` 0 its
/// length. Returns that count, or -1 with `errno` set (`ERANGE` when
/// `value` is too small).
long kernova_get_xattr(int descriptor, const char *name, void *value, size_t size);
#endif

#endif
