# Swift 6.4 at -Onone reads a missing key's optional-chained field as non-nil when the value holds a bare OpaquePointer

**Date:** 2026-09-30 · **Host:** M1 Max (MacBookPro18,4), macOS 27.0.1 (26A434) ·
**Toolchain:** Xcode 27.0, `Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)`,
target `arm64-apple-macosx27.0.0` · **Found by:** `VmnetNetworkServiceTests`
failing on `ipv4Subnet(for:) == nil` for a network never created (#1459)

## Summary

- Compiled at `-Onone`, `dictionary[key]?.field` returns `.some(garbage)` for
  a key the dictionary does not hold when all of these are true:
  - the dictionary is a `var` stored property of a class;
  - its value is a struct holding a non-optional `OpaquePointer`, alone or
    wrapped in a struct;
  - the field read has no spare bits, such as a struct of two `UInt32` or an
    `Int`.
- The garbage is an uninitialized stack word, often a pointer. In one run,
  `IPv4Subnet(network: 46862528, mask: 1)` held the two halves of a heap
  address.
- The same code at `-O` is correct. A Release build is unaffected. A Debug
  build, and the test suite it hosts, is not.
- Several variants are correct: a `let` stored property, a struct holding the
  dictionary, a local dictionary, a `guard let` or a local copy before the
  field read, an `OpaquePointer?`, `Bool` or class-reference payload, and a
  class wrapping the pointer.
- Inside the Kernova test host the failure is intermittent, because the
  garbage tag byte varies. Under `-enableThreadSanitizer YES` it was
  deterministic. Standalone it was deterministic either way.

## Repro

```swift
struct Handle { let pointer: OpaquePointer }
struct Subnet: Equatable { let network: UInt32; let mask: UInt32 }
struct Materialized { let handle: Handle; let subnet: Subnet }
enum Kind: String, Hashable { case hostOnly, shared }

final class Service {
    var networks: [Kind: Materialized] = [:]
    func subnet(for kind: Kind) -> Subnet? { networks[kind]?.subnet }
}

@inline(never) func probe() -> Subnet? { Service().subnet(for: .shared) }

var bad = 0
for _ in 0..<1000 where probe() != nil { bad += 1 }
print("garbage results: \(bad) of 1000")
```

`xcrun swiftc -Onone repro.swift -o plain && ./plain` printed
`garbage results: 1000 of 1000`; with `-sanitize=thread` added, the same.

## Shape matrix (`-Onone`, 200 calls each, missing key)

| Holder | Value | Read | Wrong |
|---|---|---|---|
| class `var` | `{Handle(OpaquePointer), Subnet}` | `?.subnet` | 200 |
| class `let` | same | `?.subnet` | 0 |
| class `var` | same | `guard let`, then `.subnet` | 0 |
| class `var` | same | local copy, then `?.subnet` | 0 |
| class `var` | `{OpaquePointer?, Subnet}` | `?.subnet` | 0 |
| class `var` | `{Int, Subnet}` | `?.subnet` | 0 |
| class `var` | `[Kind: Subnet]` | subscript | 0 |
| struct `var` | `{Handle, Subnet}` | `?.subnet` | 0 |
| generic class `var` | `{OpaquePointer, Subnet}` | `?.value` | 200 |
| generic class `var` | `{OpaquePointer, Int}` | `?.value` | 200 |
| generic class `var` | `{OpaquePointer, Bool}` | `?.value` | 0 |
| generic class `var` | `{class ref, Subnet}`, `{String, Subnet}`, `{URL, Subnet}`, `{class ref, Int}`, `{String, UUID}` | `?.value` | 0 each |
| class `var`, keyed by `{String, UUID?}`, behind `NSLock.withLock` | `{final class wrapping OpaquePointer, Subnet}` | `?.subnet` and `?.handle`, then a hit | 0 of 1500 (also under TSan) |
| same | `{struct wrapping OpaquePointer, Subnet}` | same | 250 of 1500 |

Every row also returned the right answer at `-O`.

## Method

Standalone files compiled with `xcrun swiftc` at `-Onone`, `-O` and
`-Onone -sanitize=thread`, each calling an `@inline(never)` reader in a loop and
counting non-nil answers for a key never inserted. In the app, a throwaway
Swift Testing suite in KernovaTests ran the same shapes through `make
test-suite` with `CI_FLAGS="-enableThreadSanitizer YES"`.
