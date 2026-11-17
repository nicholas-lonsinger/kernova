# The sandboxed app cannot end a VM's process

**Date:** 2026-11-17 · **Host:** macOS 27.2.1, Virtualization 308.2.7,
Kernova Debug build of `3011efc4` plus a probe (App Sandbox on) ·
**Guest:** Ubuntu Desktop 26.04.1

## Finding

With a VM's `com.apple.Virtualization.VirtualMachine` process frozen by
`SIGSTOP`, `VZVirtualMachine.stop(completionHandler:)` does not call its
completion handler, and nothing Kernova can do from inside its sandbox ends
the process.

| Route, tried from the app 12–15 s into the unanswered stop | Result |
|---|---|
| `proc_listallpids` | returns 0, `EPERM` |
| `sysctl` `KERN_PROC_ALL` | returns no process |
| `kill(pid, 0)` on the VM process and on every other live pid in the 4000 above the app's | `EPERM` for each; none permitted |
| Clear `VZVirtualMachineView.virtualMachine` and drop the session's own references to the `VZVirtualMachine` | the object is not deallocated; the process is still stopped 45 s later |

Virtualization's own attempt logs `(libxpc.dylib) Could not signal service
com.apple.Virtualization.VirtualMachine: 1: Operation not permitted` 8 s
after the stop, and leaves an `ExcUserFault_Kernova` report.

The `kernova` tool in the app bundle carries `com.apple.security.app-sandbox`
too.

`kill -9` from Terminal ends the process. The delegate's
`virtualMachine(_:didStopWithError:)` and the stop's completion handler then
both arrive, each with `VZErrorDomain` code 1, "The virtual machine stopped
unexpectedly."

`lsappinfo` names the process "Virtual Machine Service for Kernova"; its
bundle's `CFBundleDisplayName` is "Virtual Machine Service".

## Which process is a VM's

Each VM process holds files in its own VM's bundle open — `Disk.asif` and
`EFIVariableStore` on this guest — and Kernova holds neither. With two
clones running, started in the same second:

```
lsof -t -c com.apple.Virtualization -a +D "<bundle>"
```

printed one pid for each bundle, the same one before and after that
process was frozen. `kill -9` on the frozen clone's pid, 12 s into its
unanswered Force Stop, settled that clone in Error and left the other
running.

The same command, pasted into Terminal.app on this Mac, ended the frozen
process of a macOS 26.7.2 guest with no privacy prompt and no output, and
left a Linux guest running.

## Method

A probe in `VMSession.stop()` logged the stop, then ran the table's calls on
a thread of its own. `kernova clone --new-machine` of a stopped Linux guest,
`kernova start`, 20 s, `kill -STOP` on the one VM process, `kernova stop
--force`, then `ps` on the process at 10–60 s and `kernova list`. Three
runs; the release route in one.

## Not covered

Terminal.app on a Mac where it has never been allowed to read another
app's container. A VM process stuck the way the ASIF deadlock leaves it, where the stop's
completion handler was observed never to run even after the kill. The same
calls from an unsandboxed process. What still held the `VZVirtualMachine`
after Kernova's references were dropped.
