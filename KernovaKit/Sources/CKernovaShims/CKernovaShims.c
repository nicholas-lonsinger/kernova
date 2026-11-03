#if defined(__linux__)
#define _GNU_SOURCE
#endif

#include "CKernovaShims.h"

#include <string.h>

#if defined(_WIN32)
#include <windows.h>
#include <realtimeapiset.h>
#else
#include <time.h>
#endif

#if defined(__aarch64__) || defined(_M_ARM64)
#include <arm_acle.h>

__attribute__((target("crc")))
uint32_t kernova_crc32c_hardware_update(uint32_t crc, const uint8_t *bytes, size_t count) {
    while (count >= 8) {
        uint64_t word;
        memcpy(&word, bytes, sizeof word);
        crc = __crc32cd(crc, word);
        bytes += 8;
        count -= 8;
    }
    while (count > 0) {
        crc = __crc32cb(crc, *bytes);
        bytes += 1;
        count -= 1;
    }
    return crc;
}

#elif defined(__x86_64__) || defined(_M_X64)
#include <nmmintrin.h>

__attribute__((target("sse4.2")))
uint32_t kernova_crc32c_hardware_update(uint32_t crc, const uint8_t *bytes, size_t count) {
    uint64_t wide = crc;
    while (count >= 8) {
        uint64_t word;
        memcpy(&word, bytes, sizeof word);
        wide = _mm_crc32_u64(wide, word);
        bytes += 8;
        count -= 8;
    }
    crc = (uint32_t)wide;
    while (count > 0) {
        crc = _mm_crc32_u8(crc, *bytes);
        bytes += 1;
        count -= 1;
    }
    return crc;
}

#endif

#if defined(__APPLE__)

uint64_t kernova_monotonic_nanoseconds(void) {
    return clock_gettime_nsec_np(CLOCK_MONOTONIC);
}

#elif defined(_WIN32)

uint64_t kernova_monotonic_nanoseconds(void) {
    ULONGLONG hundreds;
    QueryInterruptTimePrecise(&hundreds);
    return (uint64_t)hundreds * 100;
}

#else

uint64_t kernova_monotonic_nanoseconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_BOOTTIME, &now);
    return (uint64_t)now.tv_sec * 1000000000u + (uint64_t)now.tv_nsec;
}

#endif

#if defined(__linux__)
#include <errno.h>
#include <sys/socket.h>
#include <unistd.h>
#include <linux/vm_sockets.h>
#include <sys/syscall.h>

int kernova_vsock_connect(uint32_t cid, uint32_t port, int *in_progress) {
    int descriptor = socket(AF_VSOCK, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (descriptor < 0) {
        return -1;
    }
    struct sockaddr_vm address;
    memset(&address, 0, sizeof address);
    address.svm_family = AF_VSOCK;
    address.svm_cid = cid;
    address.svm_port = port;
    if (connect(descriptor, (const struct sockaddr *)&address, sizeof address) == 0) {
        *in_progress = 0;
        return descriptor;
    }
    if (errno == EINPROGRESS) {
        *in_progress = 1;
        return descriptor;
    }
    int saved = errno;
    close(descriptor);
    errno = saved;
    return -1;
}

// `struct open_how` and `RESOLVE_BENEATH` from the kernel's
// `include/uapi/linux/openat2.h`, which the static Linux SDK does not ship;
// the layout and the value are kernel ABI.
struct kernova_open_how {
    uint64_t flags;
    uint64_t mode;
    uint64_t resolve;
};
#define KERNOVA_RESOLVE_BENEATH 0x08

int kernova_openat2(int directory, const char *name, int flags, uint32_t mode, int resolve_beneath) {
    struct kernova_open_how how;
    memset(&how, 0, sizeof how);
    how.flags = (uint64_t)(uint32_t)flags;
    how.mode = mode;
    how.resolve = resolve_beneath ? KERNOVA_RESOLVE_BENEATH : 0;
    return (int)syscall(SYS_openat2, directory, name, &how, sizeof how);
}

// `RENAME_NOREPLACE` from the kernel's `include/uapi/linux/fs.h`.
#define KERNOVA_RENAME_NOREPLACE 1

int kernova_rename_exclusive(int directory, const char *name, int new_directory, const char *new_name) {
    return (int)syscall(SYS_renameat2, directory, name, new_directory, new_name, KERNOVA_RENAME_NOREPLACE);
}

// `FALLOC_FL_KEEP_SIZE` and `FALLOC_FL_PUNCH_HOLE` from the kernel's
// `include/uapi/linux/falloc.h`.
#define KERNOVA_FALLOC_FL_KEEP_SIZE 0x01
#define KERNOVA_FALLOC_FL_PUNCH_HOLE 0x02

int kernova_punch_hole(int descriptor, int64_t offset, int64_t length) {
    return (int)syscall(
        SYS_fallocate, descriptor, KERNOVA_FALLOC_FL_PUNCH_HOLE | KERNOVA_FALLOC_FL_KEEP_SIZE, (off_t)offset,
        (off_t)length);
}

int kernova_set_xattr(int descriptor, const char *name, const void *value, size_t size) {
    return (int)syscall(SYS_fsetxattr, descriptor, name, value, size, 0);
}
#endif
