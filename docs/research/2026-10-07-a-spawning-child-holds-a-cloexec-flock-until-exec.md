# A child being spawned holds a close-on-exec `flock` descriptor until its exec

**Date:** 2026-10-07 · **Host:** M1 Max (MacBookPro18,4), macOS 27.2
(26B5101f), APFS · **Tools:** Apple clang 21.0.0 · **Found by:**
`ExclusiveFileLockSandboxTests.creatingAcquireRefusesSecondUntilReleased`
failing once on its re-acquire after release (#1533)

## Summary

- While any thread of a process spawns a child, the child briefly holds a
  reference to each of the parent's open file descriptions. That includes
  ones opened `O_CLOEXEC`, and `posix_spawn` with `POSIX_SPAWN_CLOEXEC_DEFAULT`
  as well as `fork` + `execve`.
- A `flock` lock taken by `open(O_EXLOCK)` and released by `close` alone
  stays held until that child's exec drops the reference. A re-acquire of the
  same path in that window gets `EWOULDBLOCK`.
- `flock(fd, LOCK_UN)` before `close` releases the lock whatever other
  references exist. Under the same spawn load it never failed.

**Documented.** `man 2 flock`: "file descriptors duplicated through dup(2) or
fork(2) do not result in multiple instances of a lock, but rather multiple
references to a single lock. If a process holding a lock on a file forks and
the child explicitly unlocks the file, the parent will lose its lock."

## Observed

A probe ran a lock loop on one thread while four other threads spawned
`/usr/bin/true` and waited for it, over and over. Each of the 100,000
iterations did these steps:

1. Acquire with `open(path, O_RDONLY|O_CREAT|O_EXLOCK|O_NONBLOCK|O_CLOEXEC)`.
2. Release.
3. Acquire again the same way.
4. Release.

"First acquire refused" counts step 1 failing, because the previous
iteration's lock was still held through a child.

| Spawner threads | Release | Re-acquire refused | First acquire refused |
|---|---|---|---|
| none | `close` | 0 | 0 |
| `posix_spawn` | `close` | 109 | 8,981 |
| `posix_spawn` + `POSIX_SPAWN_CLOEXEC_DEFAULT` | `close` | 140 | 14,752 |
| `fork` + `execve` | `close` | 99 | 19,868 |
| `posix_spawn` | `flock(LOCK_UN)`, `close` | 0 | 0 |
| `posix_spawn` + `POSIX_SPAWN_CLOEXEC_DEFAULT` | `flock(LOCK_UN)`, `close` | 0 | 0 |
| `fork` + `execve` | `flock(LOCK_UN)`, `close` | 0 | 0 |

Every refusal was `EWOULDBLOCK`.

## Method

`race.c`: `race <mode> <iterations> <path> <threads>`. Mode 0 starts no
spawners. Mode 1 runs `posix_spawn` with default attributes, mode 2 adds
`POSIX_SPAWN_CLOEXEC_DEFAULT`, and mode 3 runs `fork` then `execve`. Each
spawner thread spawns `/usr/bin/true` and `waitpid`s for it until the lock
loop ends. The lock loop does the four steps above on `<path>`, counting
`EWOULDBLOCK` at each acquire. The `LOCK_UN` rows come from the same file
with `flock(fd, LOCK_UN)` inserted before each `close`. Built with
`clang -O2`, and run unsandboxed as
`./race <mode> 100000 <dir>/lock<mode>.lock 4`, one fresh lock file per run.
