# File coordination, directory renames and `flock` across processes

**Date:** 2026-09-24 · **Host:** M1 Max (MacBookPro18,4), 32 GB, macOS 27.0
(26A428), APFS · **Tools:** Xcode 27.0 (27A266a), Apple Swift 6.4, Apple
clang 21.0.0 · **Subjects:** probe command-line tools, run unsandboxed and as
two separately built sandboxed copies sharing one container; `.kernova` was
registered with LaunchServices as `app.kernova.vm` conforming to
`com.apple.package`

Each claim is tagged **Documented** (source given) or **Observed** (the
Method step that reproduces it, and an output excerpt). Times are wall-clock
waits measured in the requesting process.

## File coordination crosses processes and the App Sandbox

**Documented.** `NSFileCoordinator.h` (same text on
developer.apple.com/documentation/foundation/nsfilecoordinator): the class
"coordinates the reading and writing of files and directories among multiple
processes and objects in the same process", and presenters are messaged
"even those in other processes". The header's only sandbox wording concerns
related items (`primaryPresentedItemURL`); it states no entitlement,
bundle-identifier or team condition for coordination. The File System
Programming Guide
([The Role of File Coordinators and Presenters](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileCoordinators/FileCoordinators.html))
advises "If your app runs in a sandbox, you also do not need to monitor any
files you create inside your sandbox directory."

**Observed** (Method 2 and 4). Process A held a coordinated write on
`config.json` for 3 s while process B asked for access:

| B's request | Unsandboxed wait | Two sandboxed builds, shared container |
|---|---|---|
| Write the same `config.json` in `pkg.kernova` | 2.659 s | — |
| Write sibling `other.json` in `pkg.kernova` | 2.516 s | 2.490 s |
| Coordinated read of sibling `other.json` in `pkg.kernova` | 2.503 s | — |
| Write sibling `other.json` in `plain.dir` | 0.008 s | 0.008 s |
| Coordinated read of sibling in `plain.dir` | 0.008 s | — |

```
1790288473.703 pid=85224 B cwrite requested
1790288476.182 pid=85222 A cwrite accessor end
1790288476.193 pid=85224 B cwrite GRANTED after 2.490s
```

The two sandboxed builds had different CDHashes, one signing identifier and
one team; each ran with `HOME` set to the container, and a write outside it
failed with `NSCocoaErrorDomain 513` / `EPERM`.

## Package-wide scope follows the registered type, not the bundle bit

**Documented.** `NSFileCoordinator.h`: "Coordinated reading or writing of
items in a file package is treated as coordinated reading or writing of the
file package as a whole", and "A coordinated reader of a directory that is not
a file package does not wait for coordinated writers of contained items, or
cause such writers to wait."

**Observed** (Method 2, 3). The sibling-write test in a directory whose
extension no application declares, with the Finder bundle bit set
(`NSURLIsPackageKey` true, `com.apple.FinderInfo` flags `0x2000`), granted B
at once, as for a plain folder; in `pkg.kernova` (type registered, conforming
to `com.apple.package`) B waited for A:

```
=== bundlebit.zzqpkg  isPackage=true  FinderInfo=000000000000000020000000
1790288371.991 pid=85066 B cwrite GRANTED after 0.008s
```

## A presenter on a package sees every sub-item change, coordinated or not

**Documented.** `NSFilePresenter.h` states both "Your presenter objects are not
notified about changes made directly using low-level read and write calls to
the file. Only changes that go through a file coordinator result in
notifications" and, on `presentedItemDidChange` and the directory methods,
"Not all programs use file coordination. Your NSFilePresenter may be sent this
message without being sent -relinquishPresentedItemToWriter: first." For a
package that does not implement `presentedSubitemDidAppearAtURL:` or
`presentedSubitemAtURL:didMoveToURL:`, "the file coordination machinery will
invoke -presentedItemDidChange instead."

**Observed** (Method 2, 4). A presenter in process A implemented every
directory and sub-item method; another process then changed the presented
directory, 1.5 s apart. Every change arrived as
`presentedSubitemDidChange(at:)`, 0.5 to 1.1 s after it was made, unsandboxed
and between the sandboxed builds alike:

| Change by the other process | Presenter on `pkg.kernova` | Presenter on `plain.dir` |
|---|---|---|
| Coordinated write of existing `config.json` | `relinquishToWriter`, then `presentedSubitemDidChange config.json` | `presentedSubitemDidChange config.json` only |
| Coordinated write creating `new1.json` | `relinquishToWriter`, `presentedSubitemDidChange new1.json` | `presentedSubitemDidChange new1.json` |
| Coordinated delete (`.forDeleting`) | `relinquishToWriter`, `accommodatePresentedSubitemDeletion new1.json`, `presentedSubitemDidChange new1.json` | `presentedSubitemDidChange new1.json` |
| Uncoordinated `Data.write`, plain or `.atomic` | `presentedSubitemDidChange config.json` | same |
| Uncoordinated shell `>>`, `cp`, `rm`, `touch` | `presentedSubitemDidChange <name>` | same |
| Uncoordinated `mv new2.json new3.json` | `presentedSubitemDidChange` for both names | same |
| Uncoordinated `mkdir sub` and a write inside it | `presentedSubitemDidChange` for `sub` and `deep.json` | same |

No `presentedSubitemDidAppear`, `presentedSubitem(at:didMoveTo:)` or
`presentedItemDidChange` call was logged in any run. An `.atomic` write made
unsandboxed also reported its temporary sibling (`config.json.sb-…`).

```
1790287890.814 STEP UNcoordinated cp new file new2.json
1790287891.893 pid=84455 A presentedSubitemDidChange new2.json
```

## A presenter makes the next coordinated access to its package wait about half a second

**Documented.** `NSFileCoordinator.h`: "coordinated reads and writes also wait
for messages to be sent to NSFilePresenters registered for relevant URLs, and
for their responses to those messages", and a coordinator created with
`-initWithFilePresenter:` does not message that presenter.

**Observed** (Method 5). With a presenter registered on the package in
another process, a coordinated write is granted in about 10 ms, and the next
coordinated read or write of anything in that package waits until the
presenter has been sent its change notification, about 0.53 s later:

```
1790288203.351 pid=84970 B cwrite GRANTED after 0.011s
1790288203.897 pid=84971 B cread GRANTED after 0.532s
```

Back-to-back coordinated writes into one package:

| Presenters for that package | Median | Max |
|---|---|---|
| None | 1.38 ms | 3.81 ms |
| One in another process, implementing relinquish and save | 541.14 ms | 547.11 ms |
| One in another process, implementing only change callbacks | 541.06 ms | 546.69 ms |
| One in another process, sandboxed builds | 540.54 ms | 547.96 ms |
| One of 200 change-callback-only presenters in another process | 540.74 ms | 551.80 ms |
| One of 50 / 500 full presenters in another process | 540.96 / 541.27 ms | 548.27 / 612.95 ms |
| One in the same process, coordinator created with that presenter | 2.26 ms | 8.17 ms |
| One in the same process, coordinator created with `nil` | 539.75 ms | 545.77 ms |

A write into a package no presenter covers stayed at 1.41–1.45 ms median
while 50 or 500 other packages were presented.

## An unanswered or suspended presenter stalls other processes' coordinated writes

**Documented.** `NSFilePresenter.h`, `relinquishPresentedItemToReader:`: "The
system waits for you to execute that block before allowing the reader to
operate on the file. Therefore, failure to execute the block could stall
threads in your application or other processes." TN2408
([Accessing Shared Data from an App Extension and its Containing App](https://developer.apple.com/library/archive/technotes/tn2408/_index.html)):
"File coordination does not have a mechanism for handling process
suspensions."

**Observed** (Method 6):

| Presenter on `pkg.kernova` in process A | B's coordinated write of `config.json` |
|---|---|
| `relinquishToWriter` never calls its block | Waited until B's own `cancel()` at 8 s (6 s sandboxed): `NSCocoaErrorDomain 3072` |
| same presenter, B's coordinated **read** | Granted in 0.010 s |
| same presenter, B writes a file outside the package | Granted in 0.005 s |
| same presenter, A `kill -9`'d 3 s into B's wait | Granted 3.026 s after the request |
| normal presenter, A `SIGSTOP`'d | Waited until `cancel()` at 6 s; A logged `relinquishToWriter` once continued |
| presenter implementing only change callbacks, A `SIGSTOP`'d | Granted in 0.008 s |

```
1790287932.324 pid=84631 A relinquishToWriter (HANGING)
1790287940.716 pid=84633 B cwrite FAILED after 8.399s: NSCocoaErrorDomain 3072
```

## Presenter registration is cheap

**Documented.** Apple's presenter documentation states no limit or
per-presenter cost. `NSFilePresenter.h`, `presentedItemURL`: "If this object
presents a group of related files that all reside in the same directory,
specify the URL of the directory instead of creating separate presenter
objects for each file."

**Observed** (Method 5). One process registering one presenter per package
directory:

| Presenters | Time to register | Process RSS | `filecoordinationd` RSS |
|---|---|---|---|
| 0 | — | 5.8 MB | 16.0 MB |
| 50 | 0.004 s | 8.8 MB | 16.1 MB |
| 200 (change callbacks only) | 0.017 s | 9.8 MB | — |
| 500 | 0.036 s | 11.0 MB | 22.8 MB |

## Moving a staged directory into place

**Documented.** `man 2 rename`:

- `rename()`: "If new exists, it is first removed", and it "guarantees that an
  instance of new will always exist, even if the system should crash in the
  middle of the operation". A directory `new` that is not empty fails with
  `ENOTEMPTY`.
- `RENAME_EXCL`: "On file systems that support it (see getattrlist(2)
  VOL_CAP_INT_RENAME_EXCL), it will cause EEXIST to be returned if the
  destination already exists."
- `RENAME_SWAP`: "On file systems that support it (see getattrlist(2)
  VOL_CAP_INT_RENAME_SWAP), it will cause the source and target to be
  atomically swapped." Source and target need not be the same type.
- `renameatx_np` takes the same flags relative to directory descriptors.

`NSFileManager.h`, `moveItemAtURL:toURL:error:`: "If an item with the same
name already exists at dstURL, this method stops the move attempt and returns
an appropriate error." `replaceItemAtURL:withItemAtURL:…`: "Replaces the
contents of the item at the specified URL in a manner that ensures no data
loss occurs", same volume only. Neither is documented as atomic.

**Observed** (Method 7–10):

- APFS reports `VOL_CAP_INT_RENAME_SWAP` and `VOL_CAP_INT_RENAME_EXCL` set
  and `VOL_CAP_INT_RENAME_OPENFAIL` clear, on the scratch volume and on
  `~/Library`.
- `renamex_np(RENAME_EXCL)` of a directory returned `EEXIST` onto an existing
  empty directory, a non-empty directory, and a regular file, and succeeded
  onto an absent name. `rename()` onto an existing empty directory replaced
  it.
- `renamex_np(RENAME_SWAP)` swapped two non-empty directories, also with a
  file open inside the source.
- `FileManager.moveItem` onto an existing directory issued no rename call and
  returned `NSCocoaErrorDomain 516` over `NSPOSIXErrorDomain 17`; onto an
  absent name it called plain `rename(src, dst)`. The existence check and the
  rename are separate steps.
- `FileManager.replaceItemAt` with both directories present called
  `renamex_np(staged, dest, RENAME_SWAP)` and then removed the old tree at the
  staged path. With the original absent, it called `rename(staged, dest)` and
  succeeded, for a regular file and for a directory.

```
  [syscall] renamex_np(staged.kernova, dest.kernova, RENAME_SWAP ) = 0
   replaceItemAt: ok result=dest.kernova dest now: staged  staged exists: false
```

Eight processes publishing to one name at the same instant, 40 trials each:

| Operation | Staged directories | Trials with other than one success | Most successes in one trial | Losers' errors |
|---|---|---|---|---|
| `moveItem` | empty | 40 | 8 | — |
| `moveItem` | one file each | 0 | 1 | 273 × `NSCocoaErrorDomain 512` over POSIX 66 (`ENOTEMPTY`), 7 × `516` over POSIX 17 |
| `rename()` | empty | 40 | 8 | — |
| `rename()` | one file each | 0 | 1 | — |
| `renamex_np(RENAME_EXCL)` | empty | 0 | 1 | — |
| `renamex_np(RENAME_EXCL)` | one file each | 0 | 1 | — |

A thread polling `stat(dest.kernova/config.json)` while the directory was
replaced 2,000 times:

| Replacement | Polls | Polls finding the path missing |
|---|---|---|
| `replaceItemAt` | 883,253 | 0 |
| `renamex_np(RENAME_SWAP)`, then remove the old tree | 544,173 | 0 |
| `removeItem(dest)`, then `moveItem(staged, dest)` | 469,031 | 177,426 |

## `F_GETLK` sees another process's `flock`

**Documented.** `man 2 fcntl`, `F_GETLK`: "If a lock that does not support the
discovery of lock ownership by process (such as an OFD lock (see below), one
created by the flock(2) system call or the open(2) system call with the
O_SHLOCK or O_EXLOCK flag) is found, l_pid is set to -1." Also "All locks
associated with a file for a given process are removed when the process
terminates." `man 2 flock`: "Locks are on files, not file descriptors. That
is, file descriptors duplicated through dup(2) or fork(2) do not result in
multiple instances of a lock, but rather multiple references to a single
lock." `man 2 open`: "a lock with flock(2) semantics can be obtained by
setting O_SHLOCK for a shared lock, or O_EXLOCK for an exclusive lock", failing
with `EWOULDBLOCK` "if … the file is locked and the O_NONBLOCK option was
specified".

**Observed** (Method 11, 12). Holder A, prober B, same file:

| A holds | B: `F_GETLK` asking write | asking read | `flock(LOCK_SH\|LOCK_NB)` | `open(O_EXLOCK\|O_NONBLOCK)` |
|---|---|---|---|---|
| nothing | `F_UNLCK` | `F_UNLCK` | granted | granted |
| `flock(LOCK_EX)` | `F_WRLCK l_pid=-1` | `F_WRLCK l_pid=-1` | `EAGAIN` | `EAGAIN` |
| `flock(LOCK_SH)` | `F_RDLCK l_pid=-1` | `F_UNLCK` | granted | `EAGAIN` |
| `open(O_EXLOCK\|O_NONBLOCK)` | `F_WRLCK l_pid=-1` | `F_WRLCK l_pid=-1` | `EAGAIN` | `EAGAIN` |

- B's result was the same with its descriptor opened `O_RDONLY` or `O_RDWR`,
  and `F_OFD_GETLK` answered as `F_GETLK` did.
- A opening and closing a second descriptor on the file left its `flock` in
  place.
- After `kill -9` of A, B found the file unlocked.
- A's lock taken without `O_CLOEXEC`, then `posix_spawn` of `/bin/sleep 60`,
  then `kill -9` of A: B still found `F_WRLCK l_pid=-1` until the child was
  killed. With `O_CLOEXEC`, B found it unlocked once A was killed.
- A process holding `flock(LOCK_EX)` on one descriptor gets
  `F_WRLCK l_pid=-1` from `F_GETLK` on a second descriptor of its own.
- Between the two sandboxed builds, on a file in their shared container, build
  B's `F_GETLK` answered `F_UNLCK` before build A locked it, `F_WRLCK l_pid=-1`
  while A held `flock(LOCK_EX)`, and `F_UNLCK` after `kill -9` of A.

```
1790288867.847 pid=88416 B(held) getlk r=0 l_type=F_WRLCK l_pid=-1
1790288867.866 pid=88417 B(after kill -9) getlk r=0 l_type=F_UNLCK l_pid=0
```

## File packages in the document architecture

**Documented.**
[Document-Based App Programming Guide for Mac, Advanced Topics](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/DocBasedAppProgrammingGuideForOSX/AdvancedTopics/AdvancedTopics.html):
"File wrapper (NSFileWrapper) objects that represent file packages support
incremental saving … you can write the changed object to disk but not the
unchanged ones"; NSDocument's safe save "either creates a temporary directory
in which the document writing should be done, or renames the old on-disk
revision of the document". `NSFileWrapper.h`, `NSFileWrapperWritingAtomic`:
"when overwriting a file package, the overwriting either completely succeeds
or completely fails", and "this option causes additional I/O"; writing with an
`originalContentsURL` lets unchanged children be hard-linked into the new
package. `NSFileVersion.h`: versions are added and removed "as part of a
coordinated write operation". Apple does not document where or how NSDocument
versions store a large package.

## Method

1. **Probes.** A Swift command-line probe (built with `swiftc -O`) and a C
   probe (`clang -O`), both logging `<epoch seconds.ms> pid=<pid> <label>
   <event>` lines, line-buffered, so events from several processes can be
   merged by timestamp. Scratch directories lived under the session's temp
   directory on the Data volume.
2. **Coordination probe.** Subcommands:
   - `present <dir>`: an `NSObject`/`NSFilePresenter` with a serial
     `OperationQueue` (`maxConcurrentOperationCount = 1`), registered with
     `NSFileCoordinator.addFilePresenter`, then `RunLoop.main.run()`. It
     implements `relinquishPresentedItem(toReader:)` and `(toWriter:)` (log,
     then call the block with a reacquirer that logs), `savePresentedItemChanges`,
     `accommodatePresentedItemDeletion`, `presentedItemDidMove`,
     `presentedItemDidChange`, `presentedSubitemDidAppear`,
     `presentedSubitemDidChange`, `presentedSubitem(at:didMoveTo:)` and
     `accommodatePresentedSubitemDeletion`, each logging its name and the
     item's last path component. `--hang-writer` returns from
     `relinquishPresentedItem(toWriter:)` without calling the block.
     `--no-relinquish` uses a second class implementing only
     `presentedItemDidChange`, `presentedSubitemDidAppear` and
     `presentedSubitemDidChange`.
   - `cwrite <file>` / `cread <file>` / `cdelete <item>`: one
     `NSFileCoordinator(filePresenter: nil)` call —
     `coordinate(writingItemAt:options: [])` with `Data.write(to:options: .atomic)`
     inside, `coordinate(readingItemAt:options: [])` with a read inside, or
     `coordinate(writingItemAt:options: .forDeleting)` with `removeItem`
     inside. It logs "requested", "GRANTED after <s>", "accessor end", and the
     error domain and code on failure. `--hold S` sleeps inside the accessor;
     `--timeout S` calls `cancel()` on the coordinator from a background
     queue after S seconds.
   - `uwrite <file> [--atomic]`: `Data.write` without coordination.
   Each directory under test was created fresh holding `config.json` and
   `other.json`. Exclusion runs: A `cwrite <dir>/config.json --hold 3` in the
   background, 0.5 s later B `cwrite` or `cread` of the same file or of
   `<dir>/other.json`, for `pkg.kernova` and `plain.dir`.
3. **Package detection.** Two fresh directories with an unregistered
   extension (`.zzqpkg`); on one, `URLResourceValues.isPackage = true` set
   through `setResourceValues`, checked with `xattr -px com.apple.FinderInfo`.
   Then the exclusion run of step 2 with `--hold 2`. Registration of `.kernova`
   was read with `mdls -name kMDItemContentTypeTree`.
4. **Sandboxed copies.** The coordination probe compiled twice, the second
   with an extra `-D` flag so the binaries differ, each linked with
   `-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist`
   (an `Info.plist` holding `CFBundleIdentifier`, which a sandboxed
   command-line tool needs to launch) and signed with
   `codesign -f -s "<Apple Development identity>" -i <test identifier>
   --entitlements <plist with com.apple.security.app-sandbox true> -o runtime`.
   `codesign -dvvv` showed different CDHashes and the same identifier and team
   ID. Only the sandboxed binaries touched their container
   (`~/Library/Containers/<test identifier>/Data/tmp/…`): a `mkpkg` subcommand
   created the test directories inside it, and `uwrite` made the
   uncoordinated writes. Steps 2, 5 and 6 were repeated with build A as
   holder or presenter and build B as the other process.
5. **Presenter cost and latency.** `many <root> <N>` creates N directories
   `vmNNNN.kernova`, registers one presenter on each, and logs the time taken,
   its RSS (`task_info` `MACH_TASK_BASIC_INFO`) and then runs; the
   `filecoordinationd` RSS came from `ps -o rss= -p <pid>`. `clat <file> <n>`
   times n back-to-back `cwrite`-style calls, each with a new coordinator, and
   logs median, p90 and max. `clat` ran against a file in an unpresented
   package and in `vm0007.kernova` while `many` ran with N = 50 and 500
   (full presenter) and 200 (`--no-relinquish`). The same-process case
   registers one change-callbacks-only presenter on the package and times 20
   writes with `NSFileCoordinator(filePresenter:)` bound to it, then 20 with
   `nil`.
6. **Stalls.** Presenter with `--hang-writer` on `pkg.kernova`; B
   `cwrite config.json --timeout 8`, then `cread config.json --timeout 8`, then
   `cwrite` of a file outside the package, then `cwrite --timeout 30` with
   `kill -9` of the presenter 3 s in. Separately, a normal presenter and a
   `--no-relinquish` presenter each sent `kill -STOP` before B's
   `cwrite --timeout 6`, then `kill -CONT`.
7. **Volume capabilities.** `getattrlist` with `ATTR_VOL_INFO |
   ATTR_VOL_CAPABILITIES`, reading `valid` and `capabilities` at index
   `VOL_CAPABILITIES_INTERFACES` for the three `VOL_CAP_INT_RENAME_*` bits.
8. **Syscall trace.** A C dylib built with `clang -dynamiclib` whose
   `__DATA,__interpose` section replaces `rename`, `renameat`, `renamex_np`,
   `renameatx_np`, `unlink`, `unlinkat`, `rmdir` and `clonefile` with
   wrappers that print the call, its flags and its result to stderr. It was
   loaded into the unsigned Swift rename probe with
   `DYLD_INSERT_LIBRARIES=<dylib>`, and it captured Foundation's own calls.
   The probe resets `staged.kernova` and `dest.kernova` (each holding
   `config.json` with a tag string) before each case: the raw syscalls onto
   an absent name, an empty directory, a non-empty directory and a file;
   `RENAME_SWAP` with and without an open descriptor inside the source;
   `moveItem` onto an empty directory and an absent name; `replaceItemAt`
   with the original present and absent (directory), and for a regular file
   with the original absent.
9. **Publish race.** For each of 40 trials: N = 8 staged directories (empty,
   or each holding one file), then N child processes spawned with a shared
   start time 0.3 s ahead, each busy-waiting until it and then publishing its
   own directory to `dest.kernova` with `moveItem`, `rename()` or
   `renamex_np(RENAME_EXCL)`. Each child prints "WIN", or, for `moveItem`, the
   Cocoa code and underlying POSIX code of its error. The parent counts
   winners per trial.
10. **Half-state watcher.** `dest.kernova/config.json` created; one thread
    loops `stat()` on that path, counting calls and failures, while the main
    thread 2,000 times builds `staged.kernova` with a fresh `config.json` and
    replaces `dest.kernova` by the mode under test.
11. **Locks.** A C probe. `hold <file> <flock-ex|flock-sh|oexlock> [cloexec]
    [spawn-child] [reopen-close]` takes the lock (`flock(fd, LOCK_EX|LOCK_NB)`
    or `LOCK_SH`, or `open(O_RDWR|O_CREAT|O_EXLOCK|O_NONBLOCK)`), with or
    without `O_CLOEXEC`, optionally opens and closes a second descriptor,
    optionally `posix_spawn`s `/bin/sleep 60`, prints `LOCKED` and the child's
    pid, then `pause()`s. `probe <file> [rdonly]` opens the file with
    `O_CLOEXEC`, asks `F_GETLK` for a whole-file write lock and then read lock
    (`l_start = 0`, `l_len = 0`, `SEEK_SET`), asks `F_OFD_GETLK` for a write
    lock, tries `flock(LOCK_SH|LOCK_NB)` and releases it if granted, closes,
    then tries `open(O_RDWR|O_EXLOCK|O_NONBLOCK)` and closes it if granted.
    `selfprobe <file>` takes `flock(LOCK_EX)` on one descriptor, runs
    `F_GETLK` on a second, closes it, and `posix_spawn`s `probe` as a
    separate process. Kills were `kill -9`; `kill -0` confirmed the spawned
    child outlived its parent.
12. **Locks between sandboxed builds.** Two more subcommands in the step 4
    builds: `flockhold <file>` (`open(O_RDWR|O_CREAT|O_CLOEXEC)`,
    `flock(LOCK_EX|LOCK_NB)`, run) and `getlk <file>` (`open(O_RDONLY)`,
    `F_GETLK` for a whole-file write lock). Build B probed before, while build
    A held, and after `kill -9` of A.
