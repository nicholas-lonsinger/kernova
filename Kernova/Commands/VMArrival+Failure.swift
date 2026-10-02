import Foundation

/// How an arrival's failure reaches the user — the one place a create, clone
/// or import failure is worded, whichever surface shows it.
extension VMArrival {
    /// The failure this arrival settled with, or `nil` when it was cancelled —
    /// a cancel the user took is no failure to report, and the pipeline
    /// throws every outcome of one as `CancellationError`.
    func failure(for error: any Error) -> CommandError? {
        guard !(error is CancellationError) else { return nil }
        if let command = error as? CommandError { return command }
        return .operationFailed(
            verb: kind.verb,
            title: "Couldn\u{2019}t \(kind.titleVerb) \u{201C}\(name)\u{201D}",
            message: Self.failureMessage(
                for: error, kind: kind, name: name, stagedURL: staged.url, source: source))
    }

    /// What a failed write tells the user, naming the file it failed on by the
    /// bundle the user knows: the source a clone or import copies from, or the
    /// VM being written.
    ///
    /// A Foundation file error's own description names whichever path
    /// Foundation picks — for a copy whose source is unreadable, the
    /// destination's folder under the hidden staging directory — so an error
    /// carrying any file path is worded here from its `NSFilePathErrorKey` and
    /// POSIX reason, and never rendered by its description.
    nonisolated static func failureMessage(
        for error: any Error, kind: Kind, name: String, stagedURL: URL, source: Source?
    ) -> String {
        let chain = errorChain(error)
        guard chain.contains(where: { !filePaths(in: $0).isEmpty }) else {
            return error.localizedDescription
        }
        let reason = chain.compactMap(posixReason).last
        let ending = reason.map { ": \($0)." } ?? "."
        let named = chain.lazy.compactMap(primaryPath).first

        let staged = stagedURL.standardizedFileURL
        if let named, let source,
            let relative = relativePath(of: named, under: source.bundleURL.standardizedFileURL)
        {
            return relative.isEmpty
                ? "\u{201C}\(source.label)\u{201D} could not be copied\(ending)"
                : "\u{201C}\(relative)\u{201D} in \u{201C}\(source.label)\u{201D} could not be copied\(ending)"
        }
        if let named, let relative = relativePath(of: named, under: staged) {
            return relative.isEmpty
                ? "\u{201C}\(name)\u{201D} could not be written\(ending)"
                : "\u{201C}\(relative)\u{201D} could not be written into \u{201C}\(name)\u{201D}\(ending)"
        }
        // The staged bundle sits in this process's root, inside the staging
        // directory every root shares (`ProcessStagingRoot`); nothing in it is
        // a place the user knows.
        let stagingDirectory = staged.deletingLastPathComponent().deletingLastPathComponent()
        if let named, relativePath(of: named, under: stagingDirectory) == nil {
            let path = NSString.path(withComponents: named.pathComponents)
            return "\u{201C}\(path)\u{201D} could not be accessed\(ending)"
        }
        return reason.map { "\($0)." }
            ?? "The \(kind.displayNoun.lowercased()) did not complete."
    }

    /// `error` and every error under it, outermost first.
    nonisolated private static func errorChain(_ error: any Error) -> [NSError] {
        var chain: [NSError] = []
        var next: NSError? = error as NSError
        while let current = next {
            chain.append(current)
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return chain
    }

    /// Every file path `error`'s own user info names.
    nonisolated private static func filePaths(in error: NSError) -> [URL] {
        let info = error.userInfo
        let paths = [NSFilePathErrorKey, "NSSourceFilePathErrorKey", "NSDestinationFilePath"]
            .compactMap { info[$0] as? String }
            .map { URL(fileURLWithPath: $0) }
        let url = (info[NSURLErrorKey] as? URL).flatMap { $0.isFileURL ? $0 : nil }
        return paths + (url.map { [$0] } ?? [])
    }

    /// The file `error` says it failed on.
    nonisolated private static func primaryPath(_ error: NSError) -> URL? {
        if let path = error.userInfo[NSFilePathErrorKey] as? String {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        guard let url = error.userInfo[NSURLErrorKey] as? URL, url.isFileURL else { return nil }
        return url.standardizedFileURL
    }

    /// The system's wording of `error`'s POSIX code ("Permission denied").
    nonisolated private static func posixReason(_ error: NSError) -> String? {
        guard error.domain == NSPOSIXErrorDomain else { return nil }
        return String(cString: strerror(Int32(error.code)))
    }

    /// `url`'s path below `directory`, empty for `directory` itself, or `nil`
    /// when `url` is not inside it.
    nonisolated private static func relativePath(of url: URL, under directory: URL) -> String? {
        let base = directory.pathComponents
        let components = url.pathComponents
        guard components.starts(with: base) else { return nil }
        return components.dropFirst(base.count).joined(separator: "/")
    }
}
