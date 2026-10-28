/// Writes an ECMA-119 (ISO 9660) image whose root directory holds a list of files, with Rock Ridge (RRIP
/// 1.12 over SUSP 1.12) giving each its POSIX name and permissions.
///
/// One root directory, no subdirectories and no Joliet. The image is a pure function of its inputs: the
/// files are laid out sorted by name, every timestamp is the one date given, and nothing else varies, so
/// two writes of the same inputs are byte-equal whatever order the entries come in. It streams: each
/// file's bytes go from its ``ISO9660Entry/contents`` to the sink as they come.
public struct ISO9660Writer: Sendable {
    /// The logical block size, and the size of every sector the writer emits.
    public static let blockSize = 2048

    /// The primary volume descriptor's volume identifier: what a reader shows as the disk's label.
    public let volumeIdentifier: String
    /// The date every record carries.
    public let date: ISO9660Date

    /// A writer of images labelled `volumeIdentifier`, every timestamp in them `date`.
    public init(volumeIdentifier: String, date: ISO9660Date) {
        self.volumeIdentifier = volumeIdentifier
        self.date = date
    }

    /// Writes the image holding `entries` to `sink`, one sector or more at a time.
    ///
    /// Throws ``ISO9660Error`` for inputs it cannot write, before writing anything, and whatever `sink` or
    /// an entry's `contents` throws, where it is thrown.
    public func write(_ entries: [ISO9660Entry], to sink: ISO9660Entry.Sink) throws {
        let layout = try Layout(volumeIdentifier: volumeIdentifier, date: date, entries: entries)
        let zeros = [UInt8](repeating: 0, count: Self.blockSize)
        for _ in 0..<Layout.systemAreaSectors { try sink(zeros) }
        try sink(layout.primaryVolumeDescriptor())
        try sink(layout.terminator())
        try sink(layout.pathTable(bigEndian: false))
        try sink(layout.pathTable(bigEndian: true))
        try sink(layout.rootDirectory())
        try sink(layout.continuationArea())
        for file in layout.files {
            var written: UInt64 = 0
            try file.entry.contents { bytes in
                written += UInt64(bytes.count)
                guard written <= file.entry.size else { return }
                try sink(bytes)
            }
            guard written == file.entry.size else {
                throw ISO9660Error.sizeMismatch(name: file.entry.name, declared: file.entry.size, written: written)
            }
            let tail = Int(written % UInt64(Self.blockSize))
            if tail != 0 { try sink([UInt8](repeating: 0, count: Self.blockSize - tail)) }
        }
    }
}

/// Where everything in one image goes, and the bytes of every structure that is not file data.
private struct Layout {
    static let systemAreaSectors = 16
    static let primaryVolumeDescriptorSector: UInt32 = 16
    static let lPathTableSector: UInt32 = 18
    static let mPathTableSector: UInt32 = 19
    static let rootSector: UInt32 = 20
    static let blockSize = ISO9660Writer.blockSize

    struct File {
        var entry: ISO9660Entry
        var identifier: [UInt8]
        var extent: UInt32
        var serial: UInt32
    }

    let volumeIdentifier: [UInt8]
    let date: ISO9660Date
    /// The files in directory order: by ECMA-119 identifier.
    let files: [File]
    let rootSectors: UInt32
    let continuationSector: UInt32
    let totalSectors: UInt32

    init(volumeIdentifier: String, date: ISO9660Date, entries: [ISO9660Entry]) throws {
        let volume = Array(volumeIdentifier.utf8)
        guard (1...32).contains(volume.count), volume.allSatisfy(Self.isDCharacter) else {
            throw ISO9660Error.invalidVolumeIdentifier(volumeIdentifier)
        }
        guard Self.isValid(date) else { throw ISO9660Error.invalidDate(date) }
        self.volumeIdentifier = volume
        self.date = date

        // Identifiers are assigned in name order, so the one a collision renames does not depend on the
        // order the entries came in.
        var seen = Set<String>()
        for entry in entries {
            let bytes = Array(entry.name.utf8)
            guard !bytes.isEmpty, bytes.count <= ISO9660Entry.maximumNameLength, entry.name != ".",
                entry.name != "..", !bytes.contains(0x2F), !bytes.contains(0)
            else { throw ISO9660Error.invalidName(entry.name) }
            guard entry.permissions & ~0o7777 == 0 else {
                throw ISO9660Error.invalidPermissions(name: entry.name, permissions: entry.permissions)
            }
            guard entry.size <= UInt64(UInt32.max) else {
                throw ISO9660Error.fileTooLarge(name: entry.name, size: entry.size)
            }
            guard seen.insert(entry.name).inserted else { throw ISO9660Error.duplicateName(entry.name) }
        }
        var taken = Set<[UInt8]>()
        var named: [(entry: ISO9660Entry, identifier: [UInt8])] = []
        for entry in entries.sorted(by: { Array($0.name.utf8).lexicographicallyPrecedes(Array($1.name.utf8)) }) {
            let identifier = Self.identifier(for: entry.name, avoiding: taken)
            taken.insert(identifier)
            named.append((entry, identifier))
        }
        named.sort { Self.identifierPrecedes($0.identifier, $1.identifier) }

        // The directory's size depends on no extent, so it is packed before any file is placed.
        let recordLengths =
            [Self.dotRecordLength, Self.dotDotRecordLength]
            + named.map { Self.fileRecordLength(identifier: $0.identifier, name: $0.entry.name) }
        rootSectors = Self.sectorsPacking(recordLengths)
        continuationSector = Self.rootSector + rootSectors
        var next = UInt64(continuationSector) + 1
        var files: [File] = []
        for (index, item) in named.enumerated() {
            files.append(
                File(
                    entry: item.entry, identifier: item.identifier, extent: UInt32(truncatingIfNeeded: next),
                    serial: UInt32(index + 2)))
            next += (item.entry.size + UInt64(Self.blockSize) - 1) / UInt64(Self.blockSize)
            guard next <= UInt64(UInt32.max) else { throw ISO9660Error.imageTooLarge }
        }
        self.files = files
        totalSectors = UInt32(next)
    }

    // MARK: Volume descriptors and path tables

    func primaryVolumeDescriptor() -> [UInt8] {
        var sector = [UInt8](repeating: 0, count: Self.blockSize)
        sector[0] = 1
        sector.replace(at: 1, with: Array("CD001".utf8))
        sector[6] = 1
        sector.replace(at: 8, with: Self.padded([], to: 32))
        sector.replace(at: 40, with: Self.padded(volumeIdentifier, to: 32))
        sector.replace(at: 80, with: Self.both32(totalSectors))
        sector.replace(at: 120, with: Self.both16(1))
        sector.replace(at: 124, with: Self.both16(1))
        sector.replace(at: 128, with: Self.both16(UInt16(Self.blockSize)))
        sector.replace(at: 132, with: Self.both32(UInt32(Self.pathTableLength)))
        sector.replace(at: 140, with: Self.little32(Self.lPathTableSector))
        sector.replace(at: 148, with: Self.big32(Self.mPathTableSector))
        sector.replace(
            at: 156,
            with: Self.directoryRecord(
                extent: Self.rootSector, length: rootSectors * UInt32(Self.blockSize), isDirectory: true,
                identifier: [0], systemUse: [], date: date))
        // Volume set, publisher, data preparer and application identifiers, then the copyright, abstract
        // and bibliographic file identifiers: all unrecorded.
        sector.replace(at: 190, with: Self.padded([], to: 128 * 4 + 37 * 3))
        let recorded = Self.descriptorDate(date)
        sector.replace(at: 813, with: recorded)
        sector.replace(at: 830, with: recorded)
        sector.replace(at: 847, with: Self.unspecifiedDescriptorDate)
        sector.replace(at: 864, with: Self.unspecifiedDescriptorDate)
        sector[881] = 1
        return sector
    }

    func terminator() -> [UInt8] {
        var sector = [UInt8](repeating: 0, count: Self.blockSize)
        sector[0] = 255
        sector.replace(at: 1, with: Array("CD001".utf8))
        sector[6] = 1
        return sector
    }

    /// One entry, the root's, which is its own parent.
    static let pathTableLength = 10

    func pathTable(bigEndian: Bool) -> [UInt8] {
        var sector = [UInt8](repeating: 0, count: Self.blockSize)
        sector[0] = 1
        sector.replace(at: 2, with: bigEndian ? Self.big32(Self.rootSector) : Self.little32(Self.rootSector))
        sector.replace(at: 6, with: bigEndian ? [0, 1] : [1, 0])
        return sector
    }

    // MARK: The root directory

    func rootDirectory() -> [UInt8] {
        let length = rootSectors * UInt32(Self.blockSize)
        let directoryUse = Self.px(mode: 0o040755, links: 2, serial: 1) + tf()
        var records = [
            Self.directoryRecord(
                extent: Self.rootSector, length: length, isDirectory: true, identifier: [0],
                systemUse: Self.sp + Self.ce(block: continuationSector, length: UInt32(Self.er.count))
                    + directoryUse, date: date),
            Self.directoryRecord(
                extent: Self.rootSector, length: length, isDirectory: true, identifier: [1],
                systemUse: directoryUse, date: date),
        ]
        for file in files {
            records.append(
                Self.directoryRecord(
                    extent: file.extent, length: UInt32(file.entry.size), isDirectory: false,
                    identifier: file.identifier,
                    systemUse: Self.px(mode: 0o100000 | UInt32(file.entry.permissions), links: 1, serial: file.serial)
                        + tf() + Self.nm(file.entry.name), date: date))
        }
        var bytes: [UInt8] = []
        var used = 0
        for record in records {
            // ECMA-119 9.1: no record crosses a sector boundary.
            if used + record.count > Self.blockSize {
                bytes += [UInt8](repeating: 0, count: Self.blockSize - used)
                used = 0
            }
            bytes += record
            used += record.count
        }
        bytes += [UInt8](repeating: 0, count: Int(length) - bytes.count)
        return bytes
    }

    /// The root `.` record's continuation area, holding the `ER` entry no record has room for.
    func continuationArea() -> [UInt8] {
        Self.er + [UInt8](repeating: 0, count: Self.blockSize - Self.er.count)
    }

    static var dotRecordLength: Int {
        recordLength(identifierLength: 1, systemUseLength: sp.count + 28 + 44 + 26)
    }
    static var dotDotRecordLength: Int { recordLength(identifierLength: 1, systemUseLength: 44 + 26) }

    static func fileRecordLength(identifier: [UInt8], name: String) -> Int {
        recordLength(identifierLength: identifier.count, systemUseLength: 44 + 26 + 5 + name.utf8.count)
    }

    static func recordLength(identifierLength: Int, systemUseLength: Int) -> Int {
        let length = 33 + identifierLength + (identifierLength % 2 == 0 ? 1 : 0) + systemUseLength
        return length + length % 2
    }

    static func sectorsPacking(_ lengths: [Int]) -> UInt32 {
        var sectors: UInt32 = 1
        var used = 0
        for length in lengths {
            if used + length > blockSize {
                sectors += 1
                used = 0
            }
            used += length
        }
        return sectors
    }

    /// An ECMA-119 9.1 directory record, padded to an even length.
    static func directoryRecord(
        extent: UInt32, length: UInt32, isDirectory: Bool, identifier: [UInt8], systemUse: [UInt8],
        date: ISO9660Date
    ) -> [UInt8] {
        let total = recordLength(identifierLength: identifier.count, systemUseLength: systemUse.count)
        var record: [UInt8] = [UInt8(total), 0]
        record += both32(extent)
        record += both32(length)
        record += recordingDate(date)
        record.append(isDirectory ? 0x02 : 0x00)
        record += [0, 0]
        record += both16(1)
        record.append(UInt8(identifier.count))
        record += identifier
        if identifier.count % 2 == 0 { record.append(0) }
        record += systemUse
        if record.count < total { record.append(0) }
        return record
    }

    // MARK: SUSP and Rock Ridge entries

    /// SUSP's `SP`: the root `.` record's mark that the image uses the System Use Sharing Protocol.
    static let sp: [UInt8] = [0x53, 0x50, 7, 1, 0xBE, 0xEF, 0]

    /// SUSP's `CE`: where the rest of a record's system use area continues.
    static func ce(block: UInt32, length: UInt32) -> [UInt8] {
        [0x43, 0x45, 28, 1] + both32(block) + both32(0) + both32(length)
    }

    /// SUSP's `ER`, naming RRIP 1.12 as the extension in use.
    static let er: [UInt8] = {
        let identifier = Array("IEEE_P1282".utf8)
        let descriptor = Array("THE IEEE P1282 PROTOCOL PROVIDES SUPPORT FOR POSIX FILE SYSTEM SEMANTICS.".utf8)
        let source = Array(
            "PLEASE CONTACT THE IEEE STANDARDS DEPARTMENT, PISCATAWAY, NJ, USA FOR THE P1282 SPECIFICATION.".utf8)
        return [
            0x45, 0x52, UInt8(8 + identifier.count + descriptor.count + source.count), 1,
            UInt8(identifier.count), UInt8(descriptor.count), UInt8(source.count), 1,
        ] + identifier + descriptor + source
    }()

    /// RRIP's `PX`: mode, link count, owner, group and serial number, owned by root.
    static func px(mode: UInt32, links: UInt32, serial: UInt32) -> [UInt8] {
        [0x50, 0x58, 44, 1] + both32(mode) + both32(links) + both32(0) + both32(0) + both32(serial)
    }

    /// RRIP's `NM`: the whole name.
    static func nm(_ name: String) -> [UInt8] {
        let bytes = Array(name.utf8)
        return [0x4E, 0x4D, UInt8(5 + bytes.count), 1, 0] + bytes
    }

    /// RRIP's `TF`: modification, access and attribute-change times, all the image's date.
    func tf() -> [UInt8] {
        let stamp = Self.recordingDate(date)
        return [0x54, 0x46, 26, 1, 0x0E] + stamp + stamp + stamp
    }

    // MARK: Identifiers

    static func isDCharacter(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x30...0x39).contains(byte) || byte == 0x5F
    }

    /// `name` as an ECMA-119 level 1 file identifier, `NAME.EXT;1`, unlike every one in `taken`.
    static func identifier(for name: String, avoiding taken: Set<[UInt8]>) -> [UInt8] {
        let mapped = Array(name.uppercased().utf8).map { isDCharacter($0) || $0 == 0x2E ? $0 : 0x5F }
        var stem = mapped[...]
        var suffix: ArraySlice<UInt8> = []
        if let dot = mapped.lastIndex(of: 0x2E), dot > 0 {
            stem = mapped[..<dot]
            suffix = mapped[(dot + 1)...]
        }
        let base = Array(stem.map { $0 == 0x2E ? 0x5F : $0 }.prefix(8))
        let ext = Array(suffix.map { $0 == 0x2E ? 0x5F : $0 }.prefix(3))
        func make(_ base: [UInt8]) -> [UInt8] {
            (base.isEmpty ? [0x5F] : base) + [0x2E] + ext + Array(";1".utf8)
        }
        var candidate = make(base)
        var counter = 0
        while taken.contains(candidate) {
            counter += 1
            let digits = Array(String(counter).utf8)
            candidate = make(Array(base.prefix(max(0, 8 - digits.count))) + digits)
        }
        return candidate
    }

    /// ECMA-119 9.3's order: by name, then by extension, each padded with spaces.
    static func identifierPrecedes(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        func parts(_ identifier: [UInt8]) -> ([UInt8], [UInt8]) {
            let bare = identifier.prefix { $0 != 0x3B }
            guard let dot = bare.firstIndex(of: 0x2E) else { return (Array(bare), []) }
            return (Array(bare[..<dot]), Array(bare[(dot + 1)...]))
        }
        func pad(_ bytes: [UInt8], _ count: Int) -> [UInt8] {
            bytes + [UInt8](repeating: 0x20, count: max(0, count - bytes.count))
        }
        let (lName, lExt) = parts(lhs)
        let (rName, rExt) = parts(rhs)
        let nameWidth = max(lName.count, rName.count)
        if pad(lName, nameWidth) != pad(rName, nameWidth) {
            return pad(lName, nameWidth).lexicographicallyPrecedes(pad(rName, nameWidth))
        }
        let extWidth = max(lExt.count, rExt.count)
        return pad(lExt, extWidth).lexicographicallyPrecedes(pad(rExt, extWidth))
    }

    // MARK: Numbers and dates

    static func little32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)]
    }

    static func big32(_ value: UInt32) -> [UInt8] { little32(value).reversed() }

    /// ECMA-119 7.3.3: little-endian, then big-endian.
    static func both32(_ value: UInt32) -> [UInt8] { little32(value) + big32(value) }

    /// ECMA-119 7.2.3.
    static func both16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8), UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    static func padded(_ bytes: [UInt8], to count: Int) -> [UInt8] {
        bytes + [UInt8](repeating: 0x20, count: count - bytes.count)
    }

    static func isValid(_ date: ISO9660Date) -> Bool {
        guard (1900...2155).contains(date.year), (1...12).contains(date.month), (0...23).contains(date.hour),
            (0...59).contains(date.minute), (0...59).contains(date.second)
        else { return false }
        let leap = date.year % 4 == 0 && (date.year % 100 != 0 || date.year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][date.month - 1]
        return (1...days).contains(date.day)
    }

    /// ECMA-119 9.1.5: seven bytes, years since 1900 first, UTC.
    static func recordingDate(_ date: ISO9660Date) -> [UInt8] {
        [
            UInt8(date.year - 1900), UInt8(date.month), UInt8(date.day), UInt8(date.hour), UInt8(date.minute),
            UInt8(date.second), 0,
        ]
    }

    /// ECMA-119 8.4.26.1: sixteen digits, `YYYYMMDDHHMMSScc`, then the offset from UTC.
    static func descriptorDate(_ date: ISO9660Date) -> [UInt8] {
        func digits(_ value: Int, _ count: Int) -> [UInt8] {
            let text = Array(String(value).utf8)
            return [UInt8](repeating: 0x30, count: count - text.count) + text
        }
        return digits(date.year, 4) + digits(date.month, 2) + digits(date.day, 2) + digits(date.hour, 2)
            + digits(date.minute, 2) + digits(date.second, 2) + digits(0, 2) + [0]
    }

    /// ECMA-119 8.4.26.1's "not specified".
    static let unspecifiedDescriptorDate = [UInt8](repeating: 0x30, count: 16) + [0]
}

extension Array where Element == UInt8 {
    fileprivate mutating func replace(at offset: Int, with bytes: [UInt8]) {
        replaceSubrange(offset..<offset + bytes.count, with: bytes)
    }
}
