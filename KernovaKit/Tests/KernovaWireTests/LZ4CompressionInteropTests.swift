#if canImport(Compression)
import Compression
import Foundation
import KernovaWire
import Testing

@Suite("LZ4 blocks agree with Compression's COMPRESSION_LZ4_RAW")
struct LZ4CompressionInteropTests {
    private func appleEncode(_ bytes: Data) -> Data? {
        var output = [UInt8](repeating: 0, count: bytes.count + 4_096)
        let written = bytes.withUnsafeBytes { input -> Int in
            guard let source = input.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(&output, output.count, source, bytes.count, nil, COMPRESSION_LZ4_RAW)
        }
        return written == 0 ? nil : Data(output[0..<written])
    }

    private func appleDecode(_ block: Data, size: Int) -> Data? {
        var output = [UInt8](repeating: 0, count: size + 1)
        let written = block.withUnsafeBytes { input -> Int in
            guard let source = input.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(&output, output.count, source, block.count, nil, COMPRESSION_LZ4_RAW)
        }
        return Data(output[0..<written])
    }

    @Test("Compression decodes every block this codec writes", arguments: LZ4Corpus.inputs)
    func appleDecodesSwift(_ input: LZ4Corpus.Input) {
        guard let block = LZ4Block.compress(input.bytes) else { return }
        #expect(appleDecode(block, size: input.bytes.count) == input.bytes)
    }

    @Test("This codec decodes every block Compression writes", arguments: LZ4Corpus.inputs)
    func swiftDecodesApple(_ input: LZ4Corpus.Input) throws {
        guard let block = appleEncode(input.bytes) else { return }
        let restored = try LZ4Block.decompress(block, decompressedSize: input.bytes.count, ceiling: 1 << 20)
        #expect(restored == input.bytes)
    }
}
#endif
