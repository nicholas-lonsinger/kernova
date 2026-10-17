import Foundation

/// What this VM's pending guest setup means for the Start control, the verb
/// behind it, and the download it may share with other VMs.
extension VMInstance {
    /// The flavor of the Start control for this VM: setup-flavored when a macOS
    /// install or a Linux image download is pending, reflecting what Start will
    /// actually do.
    package enum StartAction {
        case start
        case install
        case resumeInstall
        case download
        case resumeDownload

        package var label: String {
            switch self {
            case .start: "Start"
            case .install: "Install"
            case .resumeInstall: "Resume Install"
            case .download: "Download"
            case .resumeDownload: "Resume Download"
            }
        }
    }

    /// The action the Start control performs for this VM's current setup state.
    package var startAction: StartAction {
        switch configuration.pendingGuestSetup {
        case .macOSInstall:
            return hasResumableInstallDownload ? .resumeInstall : .install
        case .linuxImageDownload:
            return hasResumableInstallDownload ? .resumeDownload : .download
        case nil:
            return .start
        }
    }

    /// `true` when this VM's pending setup fetches its image, a
    /// `.kernovadownload` bundle still holds partial bytes at the chosen path,
    /// and no completed image sits at that path yet.
    ///
    /// The bytes check (`isResumable` rather than `exists`) keeps a husk left by a
    /// failed disposal from labelling a from-scratch download as a resume.
    package var hasResumableInstallDownload: Bool {
        guard let destinationURL = pendingSetupDownloadDestination else { return false }
        let bundle = DownloadBundle(url: DownloadService.resumeBundleURL(for: destinationURL))
        return bundle.isResumable
            && !FileManager.default.fileExists(atPath: destinationURL.path(percentEncoded: false))
    }

    /// The file a pending setup would download into, or `nil` when this VM's
    /// setup fetches nothing (a local IPSW or ISO, or no setup at all).
    ///
    /// A Linux catalog pick has no destination until its first resolution names
    /// the file; a URL pick names its own and carries one from the moment the VM
    /// is created.
    var pendingSetupDownloadDestination: URL? {
        switch configuration.pendingGuestSetup {
        case .macOSInstall(let context):
            return context.source.downloadsImage ? context.downloadDestinationURL : nil
        case .linuxImageDownload(let context):
            return context.downloadDestinationURL
        case nil:
            return nil
        }
    }

    /// Whether another VM in this VM's library has a pending setup that
    /// downloads into `destination` — and so may be streaming into, or waiting
    /// to resume from, the `.kernovadownload` bundle there.
    ///
    /// Destinations compare by ``DownloadService/destinationKey(for:)``, the
    /// identity the download's own claim uses. A VM outside a library has no
    /// peers, so nothing else targets its destination.
    func anotherSetupDownloads(into destination: URL) -> Bool {
        guard let peers else { return false }
        let key = DownloadService.destinationKey(for: destination)
        return peers.instances.contains { other in
            guard other !== self, let theirs = other.pendingSetupDownloadDestination else {
                return false
            }
            return DownloadService.destinationKey(for: theirs) == key
        }
    }
}
