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
