import KernovaCLICore

// The whole binary is this call: parsing, rendering and exit codes live in
// KernovaCLICore, where KernovaKitTests reaches every one of them without a
// fourth test bundle.
KernovaCommand.run()
