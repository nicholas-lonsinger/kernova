import KernovaISO9660

/// A reader of the images `ISO9660Writer` writes, independent of it: it follows ECMA-119 and SUSP from the
/// bytes alone, and refuses anything it does not find where those standards put it.
struct ISO9660Reader {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    /// One root-directory file, as a Rock Ridge reader sees it.
    struct File: Equatable {
        var identifier: String
        var name: String
        var mode: UInt32
        var links: UInt32
        var bytes: [UInt8]
        var recordedYear: Int
    }

    let image: [UInt8]
    let volumeIdentifier: String
    let volumeSpaceSize: UInt32
    let rootExtent: UInt32
    let rootLength: UInt32
    /// The extension identifiers the root's `ER` entries name.
    let extensions: [String]
    /// The root directory's own mode, from its `.` record's `PX`.
    let rootMode: UInt32
    /// The files, in directory order.
    let files: [File]

    init(_ image: [UInt8]) throws {
        self.image = image
        let block = 2048
        guard image.count % block == 0, image.count >= 21 * block else {
            throw Failure(description: "image of \(image.count) bytes")
        }
        let pvd = Array(image[16 * block..<17 * block])
        guard pvd[0] == 1, Array(pvd[1..<6]) == Array("CD001".utf8), pvd[6] == 1 else {
            throw Failure(description: "no primary volume descriptor at sector 16")
        }
        volumeIdentifier = String(decoding: pvd[40..<72], as: UTF8.self).trimmingSpaces
        volumeSpaceSize = try Self.both32(pvd, 80)
        guard Int(volumeSpaceSize) * block == image.count else {
            throw Failure(description: "volume space \(volumeSpaceSize) sectors, image \(image.count / block)")
        }
        guard try Self.both16(pvd, 128) == UInt16(block) else { throw Failure(description: "block size") }
        let terminator = image[17 * block]
        guard terminator == 255 else { throw Failure(description: "no terminator at sector 17") }
        let root = Array(pvd[156..<190])
        rootExtent = try Self.both32(root, 2)
        rootLength = try Self.both32(root, 10)
        guard root[25] & 0x02 != 0 else { throw Failure(description: "root record is not a directory") }

        let lPath = Self.little32(pvd, 140)
        let mPath = Self.big32(pvd, 148)
        for (sector, little) in [(lPath, true), (mPath, false)] {
            let entry = Array(image[Int(sector) * block..<Int(sector) * block + 10])
            let extent = little ? Self.little32(entry, 2) : Self.big32(entry, 2)
            guard entry[0] == 1, extent == rootExtent else { throw Failure(description: "path table") }
        }

        var records: [[UInt8]] = []
        let start = Int(rootExtent) * block
        var offset = start
        while offset < start + Int(rootLength) {
            let length = Int(image[offset])
            if length == 0 {
                offset = (offset / block + 1) * block
                continue
            }
            guard offset % block + length <= block else { throw Failure(description: "record crosses a sector") }
            records.append(Array(image[offset..<offset + length]))
            offset += length
        }
        guard records.count >= 2, records[0][33] == 0, records[1][33] == 1 else {
            throw Failure(description: "no . and .. records")
        }

        let dot = try Self.systemUse(records[0], image: image, followingContinuations: true)
        guard let first = dot.first, first.signature == "SP", first.data == [0xBE, 0xEF, 0] else {
            throw Failure(description: "the root's . record does not open with SP")
        }
        extensions = dot.filter { $0.signature == "ER" }.map { entry in
            let idLength = Int(entry.data[0])
            return String(decoding: entry.data[4..<4 + idLength], as: UTF8.self)
        }
        guard let dotPX = dot.first(where: { $0.signature == "PX" }) else { throw Failure(description: "no PX on .") }
        rootMode = try Self.both32(dotPX.data, 0)

        var files: [File] = []
        for record in records.dropFirst(2) {
            let idLength = Int(record[32])
            let identifier = String(decoding: record[33..<33 + idLength], as: UTF8.self)
            let entries = try Self.systemUse(record, image: image, followingContinuations: true)
            guard let px = entries.first(where: { $0.signature == "PX" }),
                let nm = entries.first(where: { $0.signature == "NM" })
            else { throw Failure(description: "\(identifier) lacks PX or NM") }
            guard px.data.count == 40 else { throw Failure(description: "\(identifier)'s PX is not RRIP 1.12's") }
            let extent = Int(try Self.both32(record, 2))
            let size = Int(try Self.both32(record, 10))
            files.append(
                File(
                    identifier: identifier, name: String(decoding: nm.data.dropFirst(), as: UTF8.self),
                    mode: try Self.both32(px.data, 0), links: try Self.both32(px.data, 8),
                    bytes: Array(image[extent * block..<extent * block + size]), recordedYear: 1900 + Int(record[18])))
        }
        self.files = files
    }

    struct SystemUseEntry {
        var signature: String
        var data: [UInt8]
    }

    /// The SUSP entries of `record`'s system use area, and of every continuation area a `CE` names.
    static func systemUse(_ record: [UInt8], image: [UInt8], followingContinuations: Bool) throws -> [SystemUseEntry] {
        let idLength = Int(record[32])
        var start = 33 + idLength
        if idLength % 2 == 0 { start += 1 }
        var areas = [Array(record[start...])]
        var entries: [SystemUseEntry] = []
        while let area = areas.first {
            areas.removeFirst()
            var offset = 0
            while offset + 4 <= area.count {
                let length = Int(area[offset + 2])
                guard length >= 4, offset + length <= area.count else { break }
                let signature = String(decoding: area[offset..<offset + 2], as: UTF8.self)
                let data = Array(area[offset + 4..<offset + length])
                if signature == "CE", followingContinuations {
                    let block = Int(try both32(data, 0))
                    let at = Int(try both32(data, 8))
                    let count = Int(try both32(data, 16))
                    areas.append(Array(image[block * 2048 + at..<block * 2048 + at + count]))
                } else if signature == "ST" {
                    break
                }
                entries.append(SystemUseEntry(signature: signature, data: data))
                offset += length
            }
        }
        return entries
    }

    static func little32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }

    static func big32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 << 8 | UInt32(bytes[offset + $1]) }
    }

    /// An ECMA-119 7.3.3 both-byte-order number, refused when its halves disagree.
    static func both32(_ bytes: [UInt8], _ offset: Int) throws -> UInt32 {
        let little = little32(bytes, offset)
        guard little == big32(bytes, offset + 4) else { throw Failure(description: "both-endian mismatch") }
        return little
    }

    static func both16(_ bytes: [UInt8], _ offset: Int) throws -> UInt16 {
        let little = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        guard little == UInt16(bytes[offset + 2]) << 8 | UInt16(bytes[offset + 3]) else {
            throw Failure(description: "both-endian mismatch")
        }
        return little
    }
}

extension String {
    fileprivate var trimmingSpaces: String {
        var text = Substring(self)
        while text.last == " " { text.removeLast() }
        return String(text)
    }
}
