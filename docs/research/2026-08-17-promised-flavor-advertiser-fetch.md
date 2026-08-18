# A promised `public.file-url` is fetched without a paste, with no Apple Account

**Date:** 2026-08-17 · **Hardware:** M1 Max, 32 GB, macOS 27.0 host ·
**Guest:** macOS 26.6.1 under `Virtualization.framework`, agent 0.70.0 ·
**Seam:** `osascript -l JavaScript` against `NSPasteboard.general`, no Kernova
code in the path · **Tracking issue:** #542

## Summary

A pasteboard item carrying a promised `public.file-url` has its provider
invoked about 100 ms after the write, with no paste and no user action. This
holds on a machine with no Apple Account and no Universal Clipboard state at
all, and `prepareForNewContents(with: .currentHostOnly)` suppresses it
completely.

1. **The fetch is the publishing machine's own act, not a peer's.** The host
   fetches its own promise with no second device involved — publisher and
   consumer are the same machine. There is no remote pull to attribute it to.
2. **It does not need an Apple Account.** The guest has no
   `SDAirDropIDMSServiceAccountAltDSID` and no
   `com.apple.coreservices.useractivityd` preferences domain, so it holds none
   of the shared-pasteboard state the host carries, and it fetches anyway at
   the same latency.
3. **`.currentHostOnly` suppresses it, in both places.** Twenty seconds silent
   on the guest, and the provider still fires the instant the flavor is read
   deliberately — so the silence is suppression, not a blind probe.

| Arm | Machine | Apple Account | Unsolicited fire |
|---|---|---|---|
| plain | host | yes | +0.106 s |
| `.currentHostOnly` | host | yes | none in 6 s |
| plain | guest | no | +0.108 s |
| `.currentHostOnly` | guest | no | none in 20 s |

## What was and was not measured

Measured: `NSPasteboardItemDataProvider` fires on a real pasteboard, on a
signed-in host and a signed-out guest, with a positive control per arm.

Not measured: which process issues the fetch. The in-guest unified log is not
sampled here, so the consumer is identified only by the property that scoping
the write `.currentHostOnly` stops it — that is, by its advertising
candidacy, not by name.

Kernova is excluded as the consumer rather than assumed: Clipboard Sharing was
switched **off** for the VM before the probe ran, not merely passthrough, so
the guest agent's pasteboard poll was unbound and no clipboard channel to the
host existed. The guest arms ran with the agent blind.

## Why the guest arm needs the host arm

A signed-out guest fetching its own promise is open to one alternative
reading: that the signed-in host reached across and pulled it, making this
Universal Clipboard after all. The host arm closes that off without any
appeal to pairing requirements — the same fetch happens on a machine that is
alone, at the same latency, so the mechanism has no cross-machine step in it
to gate on an account.

## Method

Publish a promised flavor, spin the run loop, and record any fire. Nothing in
the script pastes, so a fire inside the watch window came from elsewhere. The
explicit read afterwards is the control: an arm that stays silent and then
fires on demand was capable of reporting a fetch and had none to report.

```javascript
ObjC.import('AppKit');

function arm(mode, watchSeconds, providerName) {
    var t0 = $.NSDate.date, fires = [];
    var stamp = function () { return (-t0.timeIntervalSinceNow).toFixed(3); };

    ObjC.registerSubclass({
        name: providerName,
        superclass: 'NSObject',
        protocols: ['NSPasteboardItemDataProvider'],
        methods: {
            'pasteboard:item:provideDataForType:': {
                types: ['void', ['id', 'id', 'id']],
                implementation: function (pb, item, type) {
                    fires.push(stamp());
                    console.log('  FIRE t=+' + stamp() + 's type=' + ObjC.unwrap(type));
                    item.setStringForType(
                        $.NSURL.fileURLWithPath($('/tmp')).absoluteString, type);
                }
            }
        }
    });

    var pb = $.NSPasteboard.generalPasteboard;
    // NSPasteboardContentsCurrentHostOnly == 1 << 0
    if (mode === 'hostonly') { pb.prepareForNewContentsWithOptions(1); } else { pb.clearContents; }

    var item = $.NSPasteboardItem.alloc.init;
    item.setDataProviderForTypes($[providerName].alloc.init, $(['public.file-url']));
    console.log('ARM ' + mode + ' wrote=' + pb.writeObjects($([item])) + ' gen=' + pb.changeCount);

    $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(watchSeconds));
    var unsolicited = fires.length;
    if (unsolicited === 0) { console.log('  QUIET t=+' + stamp() + 's'); }

    pb.stringForType($('public.file-url'));                       // positive control
    $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(2));
    console.log('  ARMRESULT mode=' + mode + ' unsolicited=' + unsolicited +
        ' rigCanSeeFetches=' + (fires.length > unsolicited || unsolicited > 0));
    return unsolicited;
}

function run(argv) {
    var watch = parseFloat(argv[0] || '20');
    arm('plain', watch, 'ProbeProviderPlain');
    arm('hostonly', watch, 'ProbeProviderHostOnly');
    return '';
}
```

Run it as `osascript -l JavaScript probe.js 20`. To repeat the guest arm: turn
Clipboard Sharing off for the VM first, move the script in over the clipboard
before doing so, and confirm the account state in the same run —
`defaults read com.apple.sharingd SDAirDropIDMSServiceAccountAltDSID` must not
resolve. `MobileMeAccounts` is not a usable signal; it is absent on a
signed-in Mac too.

## Observed output

Guest, both arms, with the agent blind:

```
=== apple account state ===
Domain MobileMeAccounts does not exist
=== continuity daemons ===
454 useractivityd
404 sharingd
402 rapportd
ARM plain wrote=true gen=4 watch=20s
  FIRE  t=+0.108s type=public.file-url
  ARMRESULT mode=plain unsolicited=1 rigCanSeeFetches=true
ARM hostonly wrote=true gen=5 watch=20s
  QUIET t=+20.012s no unsolicited fetch
  FIRE  t=+20.015s type=public.file-url
  ARMRESULT mode=hostonly unsolicited=0 rigCanSeeFetches=true
```
