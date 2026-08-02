# macOS 12 lacks the getService selector, and Swift compiles the call ungated

**Date:** 2026-08-02 · **Host:** M1 Max, 32 GB, macOS 27.0, MacOSX27.0 SDK · **Guest:** macOS 12.7.6, Kernova library VM

## Summary

`-[NSFileProviderManager getServiceWithName:itemIdentifier:completionHandler:]`
(Swift: `getService(named:for:completionHandler:)`) is declared
`FILEPROVIDER_API_AVAILABILITY_V2_V5` = `API_AVAILABLE(macos(13.0), ios(16.0))`
on its category, and Monterey's FileProvider framework really does not
implement the selector: calling it on a 12.7.6 guest raises an unrecognized
selector through `___forwarding___` and aborts the process. The Swift
importer, however, does not surface the category-level availability —
`swiftc -typecheck -target arm64-apple-macos12.0` accepts the ungated call
with zero diagnostics — so a "compiles clean at the 12 floor" gate cannot
catch this class of break. FileProvider APIs on the 12-floor targets need
their availability read off the ObjC macros in `NSFileProviderDefines.h`,
not inferred from the compiler.

The pre-13 client route is `FileManager.getFileProviderServicesForItem(at:)`
(`API_AVAILABLE(macos(10.13))`) against the domain root's user-visible URL
(`getUserVisibleURL(for:)`, macos(11.0)); the extension-side
`NSFileProviderServicing` protocol is `FILEPROVIDER_API_AVAILABILITY_V3_IOS`
= macos(11.0), so the servicing endpoint itself exists on 12.

## Method

1. Guest agent 0.53.0 (81) on the 12.7.6 guest crash-looped on launchd's
   10 s `ThrottleInterval` from the first host policy carrying
   `clipboard=true` (stable for 25 min before it under `clipboard=false`).
   Crash report: `EXC_CRASH (SIGABRT)`, `abort()` after
   `objc_exception_throw` / `___forwarding___`, on dispatch queue
   `app.kernova.fileprovider.connector`; app-specific backtrace frames 5–7
   demangle to `FileProviderServicingConnector.init(config:)`'s connect
   closure ← `connect` ← `connectIfNeeded`.
2. MacOSX27.0 SDK: `NSFileProviderService.h` puts the manager category under
   `FILEPROVIDER_API_AVAILABILITY_V2_V5`; `NSFileProviderDefines.h` expands
   that to `API_AVAILABLE(macos(13.0), ios(16.0))`.
3. Importer probe: a five-line file calling
   `manager.getService(named:for:completionHandler:)` with no `#available`
   guard typechecks clean at `-target arm64-apple-macos12.0`.
4. Same-header audit of every other FileProvider symbol the agent-side code
   calls — `signalEnumerator(for:)`, `domains`, `add`, `removeAllDomains`,
   `waitForStabilization`, `getIdentifierForUserVisibleFile(at:)`,
   `getUserVisibleURL(for:)`, `temporaryDirectoryURL`,
   `NSFileProviderDomain(identifier:displayName:)`, `userEnabled` — lands on
   macos(11.0) via `V2_V3`/`V3_IOS` or the class-level macro; the getService
   category is the only 13.0 declaration reachable from the guest agent.
