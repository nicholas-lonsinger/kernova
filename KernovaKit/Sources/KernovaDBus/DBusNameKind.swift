/// The kinds of name a message header carries, each with its own rules.
public enum DBusNameKind: Sendable, Hashable {
    /// An interface name: two or more `.`-separated elements of
    /// `[A-Za-z0-9_]`, none starting with a digit.
    case interface
    /// A method or signal name: one element of `[A-Za-z0-9_]`, not starting
    /// with a digit.
    case member
    /// An error name, under the interface name rules.
    case error
    /// A unique (`:`-prefixed) or well-known bus name.
    case bus

    /// Whether `name` follows this kind's rules.
    public func isValid(_ name: String) -> Bool {
        let utf8 = Array(name.utf8)
        guard !utf8.isEmpty, utf8.count <= DBusLimits.maximumNameLength else { return false }
        switch self {
        case .member:
            return utf8.allSatisfy(Self.isNameCharacter) && !Self.isDigit(utf8[0])
        case .interface, .error:
            return Self.areValidElements(utf8, allowHyphen: false, allowLeadingDigit: false)
        case .bus:
            if utf8[0] == UInt8(ascii: ":") {
                return Self.areValidElements(utf8.dropFirst(), allowHyphen: true, allowLeadingDigit: true)
            }
            return Self.areValidElements(utf8, allowHyphen: true, allowLeadingDigit: false)
        }
    }

    /// At least two non-empty `.`-separated elements.
    private static func areValidElements(
        _ utf8: some Collection<UInt8>, allowHyphen: Bool, allowLeadingDigit: Bool
    ) -> Bool {
        var elementCount = 0
        var elementLength = 0
        for byte in utf8 {
            if byte == UInt8(ascii: ".") {
                guard elementLength > 0 else { return false }
                elementCount += 1
                elementLength = 0
                continue
            }
            let allowed = isNameCharacter(byte) || (allowHyphen && byte == UInt8(ascii: "-"))
            guard allowed else { return false }
            if elementLength == 0, isDigit(byte), !allowLeadingDigit { return false }
            elementLength += 1
        }
        guard elementLength > 0 else { return false }
        return elementCount + 1 >= 2
    }

    /// `[A-Za-z0-9_]`.
    static func isNameCharacter(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"):
            true
        default:
            false
        }
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }
}
