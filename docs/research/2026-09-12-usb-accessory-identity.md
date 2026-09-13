# A passed-through USB accessory comes back as a different device

**Date:** 2026-09-12 · **Host:** M1 Max, macOS 27.0 (Darwin 27.0.0), Xcode 27 /
MacOSX27.0.sdk · **Device:** Samsung USB-C flash drive `04e8:6300`, serial
`0373025010003250`, in the machine's second USB-C receptacle

## Summary

Assigning an accessory to an app in Apple's *Virtual Machine Accessories* menu
extra is an exclusive capture. Detaching it from a guest destroys that capture,
which **resets the device and re-enumerates it**: a new `IOUSBHostDevice` node,
a new registry ID, a new session ID, a new USB address. macOS then re-performs
its stored assignment about 700 ms later, so the app is handed what looks like
a second accessory and is in fact the same stick.

Nothing in `AccessoryAccess` survives that. `AAUSBAccessory` exposes a registry
ID, a device descriptor and a configuration descriptor — no name, no serial, no
location — and its matching criteria have no serial-number field, so a listener
cannot be narrowed to one physical unit. What does survive is in the IORegistry
node the registry ID resolves to, and reading it costs nothing: serial number,
vendor and product strings, `bcdDevice`, and the receptacle the device is in
were byte-identical across every re-enumeration observed.

## Capture, reset, re-enumeration

`IOUSBHostDefinitions.h`, on the option that takes a device exclusively:

> `IOUSBHostObjectInitOptionsDeviceCapture` Callers must have the
> "com.apple.vm.device-access" entitlement and the IOUSBHostDevice IOService
> object needs to have successfully been authorized by IOServiceAuthorize().
> […] Using this option will terminate all clients and drivers of the
> IOUSBHostDevice and associated IOUSBHostInterface clients besides the caller.
> Upon `destroy` of the IOUSBHostDevice, the device will be reset and drivers
> will be re-registered for matching. This option is only valid for macOS

`IOUSBHostDevice.h`, on what a reset does to the object:

> This function will reset and attempt to reenumerate the USB device. The
> current IOUSBHostDevice object and all of its children will be terminated. A
> new IOUSBHostDevice IOService object will be created and registered if the
> reset is successful and the previous object has finished terminating.

So the re-enumeration is the documented consequence of releasing a captured
device, not a defect. Attaching an accessory to a guest does *not* re-enumerate
it — the node keeps its ID and session ID and only its `UsbExclusiveOwner`
changes from `accessoryaccessd` to the Virtualization helper.

Measured detach-to-re-assignment delay, three consecutive cycles: 768 ms,
691 ms, 697 ms. It is not bounded by that: the same wait took 11.1 s once, on a
launch where the host had mounted the drive's volume and had to unmount it
before handing the accessory over. Anything waiting for an accessory to come
back has to be event-driven.

## Reading identity without opening the device

`IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(id))`
followed by `IORegistryEntryCreateCFProperties` returns the whole property set
from inside the App Sandbox, with no entitlement and no denial. The profile a
sandboxed Mac app runs under carries no rule for it:
`grep -c iokit-get-properties /System/Library/Sandbox/Profiles/application.sb`
is `0`, while roughly 180 daemon profiles do carry such rules. The entitlement
rule that does exist, in `frameworks.sb`, gates `iokit-open-user-client` for
`AppleUSBHostDeviceUserClient` / `AppleUSBHostFrameworkDeviceClient` — the
*open* path, which a property read does not take.

Where a sandbox does deny an IOKit property read, it denies silently:
`IORegistryEntryCreateCFProperties` returns `KERN_SUCCESS` with the keys
missing. An empty read is therefore indistinguishable from a device that
reports nothing, and neither can be told from a failure.

The keys are public, in
`IOKit.framework/Headers/usb/IOUSBHostFamilyDefinitions.h`:
`kUSBHostDevicePropertyVendorString`, `…ProductString`,
`…SerialNumberString`, `…SerialNumberStringIndex`, `kUSBHostPropertyLocationID`,
and `kUSBHostPortPropertyIOPortServicePath`.

Opening the accessory instead and reading its string descriptors returns the
same three strings. It is strictly worse: `AAUSBAccessory.h` documents the open
as exclusive, failing with `AAErrorCodeAccessoryNotAccessible` when something
else holds the device, and documents `close` as having "the same effect as
calling `-[IOUSBHostDevice destroy]`" — which is the reset above.

## One receptacle, two port nodes

`locationID` names a port node, not a receptacle. Every USB-C receptacle on
this machine fronts two of them, carrying different `locationID`s and the same
`UsbIOPort`:

| Receptacle (`UsbIOPort` leaf) | Port node | `locationID` | Protocol |
|---|---|---|---|
| `Port-USB-C@1` | `usb-drd0-port-hs` | `00100000` | 2.0 |
| `Port-USB-C@1` | `usb-drd0-port-ss` | `00200000` | 3.x |
| `Port-USB-C@2` | `usb-drd1-port-hs` | `01100000` | 2.0 |
| `Port-USB-C@2` | `usb-drd1-port-ss` | `01200000` | 3.x |
| `Port-USB-C@3` | `usb-drd2-port-hs` | `02100000` | 2.0 |
| `Port-USB-C@3` | `usb-drd2-port-ss` | `02200000` | 3.x |

`kUSBHostPortPropertyIOPortServicePath` is documented as the "registry path of
the IOPort service controlling the USB port's power state", and it is reached
from the device node with `IORegistryEntrySearchCFProperty` and
`kIORegistryIterateParents`. It is what names the hole in the side of the
machine; `locationID` additionally encodes the speed the device came up at.

## The serial number is optional, and unreliable where it is not

`iSerialNumber` is a string descriptor *index*, and zero means the device
declares no serial at all — which is what separates "has none" from "has one
that could not be read". The USB Mass Storage Bulk-Only Transport
specification §4.1.1 goes further and requires one of at least 12 hexadecimal
digits, unique per VID:PID. Vendors ship drives that violate it, which is why
every competing product carries a fallback: VirtualBox ticket #3422, two
identical keyboards indistinguishable by descriptor, has been open since 2009
(<https://www.virtualbox.org/ticket/3422>), and VMware Fusion's `.vmx`
`usb.autoConnect` grammar has no serial token at all, documenting the port-tree
`path:` as the answer when several devices share a product ID
(<https://knowledge.broadcom.com/external/article/343950>).

## Apple's own split between a unit and a model

CoreAudio draws the same line, and `AudioHardwareBase.h` states both halves:

> `kAudioDevicePropertyDeviceUID` A CFString that contains a persistent
> identifier for the AudioDevice. An AudioDevice's UID is persistent across
> boots. The content of the UID string is a black box and may contain
> information that is unique to a particular instance of an AudioDevice's
> hardware or unique to the CPU.

> `kAudioDevicePropertyModelUID` […] The identifier is unique such that the
> identifier from two AudioDevices are equal if and only if the two
> AudioDevices are the exact same model from the same manufacturer.

Observed on this machine: a paired set of AirPods reports
`74-77-86-68-F9-9C:input` as its device UID — the address the hardware itself
carries — while the built-in speakers report the role name
`BuiltInSpeakerDevice`. The durable key is something the device brings with it,
and where the device brings nothing, something about where it is.

## Method

A temporary probe compiled into the sandboxed app logged every IORegistry
property behind each assigned accessory at assignment, attach and withdrawal,
alongside `ioreg` samples taken every 100–120 ms across scripted attach/detach
cycles driven through `kernova usb`. Delays are differences between unified-log
timestamps (`subsystem BEGINSWITH "app.kernova"`). The receptacle and CoreAudio
tables are from standalone IOKit and CoreAudio probes run against this machine
on the date above.

Four detach cycles produced four distinct registry IDs, session IDs and USB
addresses, with serial number, vendor string, product string, `bcdDevice`,
`locationID` and `UsbDeviceSignature` unchanged across all four.

Not exercised: a physical replug into a different receptacle, two units of one
serial-less model at once, a device reporting no serial at all, and a fast user
switch — the one re-assignment case `AAUSBAccessoryListener.h` documents.
