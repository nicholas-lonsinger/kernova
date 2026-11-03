/// Finder's "Keep Both" names: an item whose name is taken lands as `report 2.pdf`, then `report 3.pdf`, the
/// number counted in after the stem, before the last extension.
///
/// The extension is what `NSString.pathExtension` reads: the bytes after the last `.`, when they are not empty
/// and hold no space, and a stem precedes them — so `.hidden` and `a.` have none and count at their end.
public enum KeepBothName {
    /// The name Keep Both tries `number`th for `name`: `name` itself for 1, otherwise `<stem> <number>` and the
    /// extension.
    ///
    /// - Parameters:
    ///   - name: The name the item would take, as the volume's raw bytes.
    ///   - number: 1 for the first try, 2 for the first counted name, and on.
    /// - Returns: The name to try.
    public static func candidate(_ name: [UInt8], _ number: Int) -> [UInt8] {
        guard number > 1 else { return name }
        let counted = Array(" \(number)".utf8)
        guard let dot = name.lastIndex(of: UInt8(ascii: ".")), dot > name.startIndex,
            dot < name.index(before: name.endIndex), !name[(dot + 1)...].contains(UInt8(ascii: " "))
        else { return name + counted }
        return Array(name[..<dot]) + counted + Array(name[dot...])
    }
}
