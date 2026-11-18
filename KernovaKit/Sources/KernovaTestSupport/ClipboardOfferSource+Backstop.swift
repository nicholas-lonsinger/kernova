import KernovaKit

extension ClipboardOfferSource {
    /// ``serve(item:representation:)`` under the backstop: a serve waits on whatever the representation comes
    /// from — a promise's call-in, an upstream pull — and none of those sets a deadline of its own.
    public func served(
        item: Int, representation: Int, fileID: String = #fileID, line: Int = #line
    ) async throws -> ClipboardServedRepresentation {
        try await Backstop("ClipboardOfferSource.serve(item:representation:)", fileID: fileID, line: line).run {
            try await self.serve(item: item, representation: representation)
        }
    }
}
