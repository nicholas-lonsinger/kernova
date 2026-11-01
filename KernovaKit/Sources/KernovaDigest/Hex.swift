/// `bytes` in lowercase hexadecimal, two digits a byte, as a digest is written.
public func lowercaseHex(_ bytes: some Sequence<UInt8>) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var text: [UInt8] = []
    for byte in bytes {
        text.append(digits[Int(byte >> 4)])
        text.append(digits[Int(byte & 0x0F)])
    }
    return String(decoding: text, as: UTF8.self)
}

/// The bytes `text` writes in hexadecimal, two digits a byte, either case; nil when it holds anything else
/// or an odd number of digits.
public func bytes(fromHex text: String) -> [UInt8]? {
    let digits = Array(text.utf8)
    guard digits.count.isMultiple(of: 2) else { return nil }
    func value(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): digit - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): digit - UInt8(ascii: "A") + 10
        default: nil
        }
    }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(digits.count / 2)
    var index = 0
    while index < digits.count {
        guard let high = value(digits[index]), let low = value(digits[index + 1]) else { return nil }
        bytes.append(high << 4 | low)
        index += 2
    }
    return bytes
}
