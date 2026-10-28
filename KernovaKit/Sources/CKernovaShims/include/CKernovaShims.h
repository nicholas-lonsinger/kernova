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

/// Makes `uid` and `gid` the calling thread's effective user and group and `gid` its only supplementary
/// group, keeping its real and saved ids, so ``kernova_restore_ids`` can return; every other thread keeps
/// its own. Returns 0, or -1 with `errno` set.
int kernova_assume_ids(uint32_t uid, uint32_t gid);

/// Makes `uid` and `gid` the calling thread's effective ids again and `groups` its supplementary groups:
/// what ``kernova_assume_ids`` replaced. Returns 0, or -1 with `errno` set.
int kernova_restore_ids(uint32_t uid, uint32_t gid, const uint32_t *groups, size_t count);
#endif

#endif
