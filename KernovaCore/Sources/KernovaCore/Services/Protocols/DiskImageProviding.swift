import Foundation

/// Abstraction for disk image creation and inspection.
package protocol DiskImageProviding: Sendable {
    func createDiskImage(at url: URL, sizeInGB: Int) async throws
}
