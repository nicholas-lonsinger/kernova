import Foundation

/// Display-ready summary of a `.kernova` bundle for the Quick Look preview.
///
/// Pure data assembled from the bundle's `config.json` plus read-only stats of
/// its primary disk image — building a model never writes to the bundle.
/// Compiled into the `KernovaQuickLook` extension (its production consumer)
/// and into the app target, where `KernovaTests` reaches it via
/// `@testable import Kernova`.
struct VMPreviewModel: Equatable, Sendable {
    /// One label/value row in the details grid.
    struct Field: Equatable, Sendable {
        var label: String
        var value: String

        /// Fraction (0…1) of the main disk's capacity consumed on disk.
        ///
        /// Rendered as a usage bar under the value. Only the Storage row sets
        /// this, and only when both figures were readable.
        var usedFraction: Double?

        init(label: String, value: String, usedFraction: Double? = nil) {
            self.label = label
            self.value = value
            self.usedFraction = usedFraction
        }
    }

    /// Lifecycle state worth badging in the header.
    enum Badge: Equatable, Sendable {
        case suspended
        case installPending

        var displayName: String {
            switch self {
            case .suspended: "Suspended"
            case .installPending: "Install Pending"
            }
        }
    }

    /// The VM's display name (`VMConfiguration.name` — bundle folder names are
    /// UUIDs, so the preview is where users see the real name).
    var name: String

    /// SF Symbol for the header tile — `VMGuestOS.iconName`, or the
    /// unreadable-bundle fallback glyph.
    var iconName: String

    var subtitle: String
    var badge: Badge?
    var fields: [Field]

    /// Trailing footer line — the VM's UUID for readable bundles.
    var footer: String

    init(configuration: VMConfiguration, layout: VMBundleLayout) {
        name = configuration.name
        iconName = configuration.guestOS.iconName
        subtitle = "\(configuration.guestOS.displayName) virtual machine"
        // Install-pending wins: a never-booted VM cannot also hold a save
        // file, and if a malformed bundle has both, the pending install is
        // the state that determines what Start will do.
        if configuration.installContext != nil {
            badge = .installPending
        } else if layout.hasSaveFile {
            badge = .suspended
        } else {
            badge = nil
        }
        fields = Self.makeFields(configuration: configuration, layout: layout)
        footer = configuration.id.uuidString
    }

    private init(
        name: String, iconName: String, subtitle: String, badge: Badge?,
        fields: [Field], footer: String
    ) {
        self.name = name
        self.iconName = iconName
        self.subtitle = subtitle
        self.badge = badge
        self.fields = fields
        self.footer = footer
    }

    /// The degraded model for a bundle whose `config.json` is missing or
    /// unreadable: identity falls back to the folder name, no detail fields.
    static func unreadable(bundleURL: URL) -> VMPreviewModel {
        VMPreviewModel(
            name: bundleURL.deletingPathExtension().lastPathComponent,
            iconName: "questionmark.square.dashed",
            subtitle: "The virtual machine configuration could not be read.",
            badge: nil,
            fields: [],
            footer: "Kernova Virtual Machine"
        )
    }

    private static func makeFields(
        configuration: VMConfiguration, layout: VMBundleLayout
    ) -> [Field] {
        var fields: [Field] = []

        // Boot mode is only a real choice on Linux (macOS has exactly one
        // valid mode — see `VMBootMode.validModes(for:)`), so macOS shows the
        // bare OS name.
        let osValue =
            switch configuration.guestOS {
            case .macOS: configuration.guestOS.displayName
            case .linux:
                "\(configuration.guestOS.displayName) · \(configuration.bootMode.displayName)"
            }
        fields.append(Field(label: "Guest OS", value: osValue))
        fields.append(Field(label: "CPU Cores", value: "\(configuration.cpuCount)"))
        fields.append(Field(label: "Memory", value: "\(configuration.memorySizeInGB) GB"))
        fields.append(
            Field(
                label: "Display",
                value:
                    "\(configuration.displayWidth) × \(configuration.displayHeight) @ \(configuration.displayPPI) PPI"
            ))
        fields.append(storageField(layout: layout))
        if let diskCount = configuration.storageDisks?.count, diskCount > 1 {
            // The list includes the bundle's primary disk, so everything past
            // the first entry is a user-added disk or installer image.
            fields.append(Field(label: "Additional Disks", value: "\(diskCount - 1)"))
        }
        fields.append(
            Field(label: "Network", value: configuration.networkEnabled ? "Enabled" : "Disabled"))

        let shared = configuration.sharedDirectories ?? []
        let sharedValue =
            shared.isEmpty ? "None" : shared.map(\.displayName).joined(separator: ", ")
        fields.append(Field(label: "Shared Folders", value: sharedValue))

        fields.append(
            Field(
                label: "Created",
                value: configuration.createdAt.formatted(date: .abbreviated, time: .shortened)))
        return fields
    }

    /// The main disk's row: live on-disk/allocated figures in the same
    /// phrasing as the settings list, plus the usage fraction for the bar.
    private static func storageField(layout: VMBundleLayout) -> Field {
        let mainDiskPath = layout.diskImageURL.lastPathComponent
        let sizes = layout.diskSizes(forRelativePath: mainDiskPath, isInternal: true)
        var usedFraction: Double?
        if let onDisk = sizes.onDiskBytes, let capacity = sizes.capacityBytes, capacity > 0 {
            usedFraction = min(1, Double(onDisk) / Double(capacity))
        }
        return Field(
            label: "Storage",
            value: diskSubtitle(sizes: sizes, path: mainDiskPath, isInternal: true),
            usedFraction: usedFraction)
    }
}
