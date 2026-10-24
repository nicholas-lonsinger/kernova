#!/bin/zsh
# Builds PromiseProbe.app and the test media into "build/Promise Probe", the
# folder the live pass drags onto a VM display. Spike for issue #1626.
set -euo pipefail
here=${0:A:h}
out="$here/build/Promise Probe"
rm -rf "$here/build"
mkdir -p "$out/PromiseProbe.app/Contents/MacOS"
swiftc -O -swift-version 5 -target arm64-apple-macos12.0 \
  "$here/PromiseProbe.swift" -o "$out/PromiseProbe.app/Contents/MacOS/PromiseProbe"
cp "$here/Info.plist" "$out/PromiseProbe.app/Contents/Info.plist"
codesign --force --sign - "$out/PromiseProbe.app"
swiftc -O -swift-version 5 "$here/MakeContent.swift" -o "$here/build/make-content"
"$here/build/make-content" "$out"
ls -la "$out"
