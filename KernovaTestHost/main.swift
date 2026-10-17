import AppKit

// The process KernovaUITests runs in: an NSApplication with no delegate and no
// window of its own. The code under test is linked into the test bundle, not
// here, so the process holds one copy of it.

// An ObjC exception raised on the main thread then takes the host down with a
// crash report; AppKit's default reports and swallows it, leaving the main
// queue undrained and every later @MainActor test hanging.
UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": true])
NSApplication.shared.run()
