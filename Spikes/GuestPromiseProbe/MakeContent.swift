// Writes the probe's test media into the folder named on the command line:
// three photos, a 4K video, and a Mail message carrying a PDF and a PNG.
//
// Spike for issue #1626; never shipped. Run through build.sh.

import AVFoundation
import AppKit
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func drawLabel(_ label: String, in context: CGContext, size: CGFloat, at point: CGPoint) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    (label as NSString).draw(
        at: point,
        withAttributes: [.font: NSFont.boldSystemFont(ofSize: size), .foregroundColor: NSColor.white])
    NSGraphicsContext.restoreGraphicsState()
}

func photo(_ label: String, from: NSColor, to: NSColor) -> CGImage {
    let width = 4032, height = 3024
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let gradient = CGGradient(
        colorsSpace: sRGB, colors: [from.cgColor, to.cgColor] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(
        gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
    drawLabel(label, in: context, size: 420, at: CGPoint(x: 300, y: 1200))
    return context.makeImage()!
}

func write(_ image: CGImage, to name: String, as type: UTType) {
    let url = output.appendingPathComponent(name)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(
        destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
    precondition(CGImageDestinationFinalize(destination), "could not write \(name)")
}

func pngData(_ image: CGImage) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
    return data as Data
}

func invoicePDF() -> Data {
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    let data = NSMutableData()
    let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &mediaBox, nil)!
    context.beginPDFPage(nil)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    ("Invoice 2026-10\nKernova promise probe" as NSString).draw(
        at: CGPoint(x: 72, y: 640), withAttributes: [.font: NSFont.systemFont(ofSize: 28)])
    NSGraphicsContext.restoreGraphicsState()
    context.endPDFPage()
    context.closePDF()
    return data as Data
}

/// A 4K HEVC movie of shifting noise, so the encoder spends its bitrate and the
/// file is large enough for its export to take measurable time.
func writeVideo(to name: String, seconds: Int) throws {
    let url = output.appendingPathComponent(name)
    let width = 3840, height = 2160, fps: Int32 = 30
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 60_000_000, AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps,
            ],
        ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
    writer.add(input)
    precondition(writer.startWriting(), "writer did not start: \(String(describing: writer.error))")
    writer.startSession(atSourceTime: .zero)

    let rowBytes = width * 4
    let spareRows = 97
    var noise = [UInt8](repeating: 0, count: rowBytes * (height + spareRows))
    noise.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }

    for frame in 0..<(seconds * Int(fps)) {
        while !input.isReadyForMoreMediaData { usleep(2_000) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = CVPixelBufferGetBaseAddress(pixels)!
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        let shift = (frame * 7) % spareRows
        noise.withUnsafeBytes { source in
            for row in 0..<height {
                memcpy(base + row * stride, source.baseAddress! + (row + shift) * rowBytes, rowBytes)
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        precondition(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    precondition(writer.status == .completed, "video failed: \(String(describing: writer.error))")
}

/// A message carrying `attachments` as base64 MIME parts, with CRLF line ends.
func mailMessage(attachments: [(name: String, type: String, data: Data)]) -> Data {
    let boundary = "PROBE-BOUNDARY-1626"
    var lines = [
        "From: Probe Sender <sender@example.com>",
        "To: Probe Recipient <recipient@example.com>",
        "Subject: Probe: invoice and site plan",
        "Date: Sat, 24 Oct 2026 10:00:00 -0700",
        "Message-ID: <probe-1626@example.com>",
        "MIME-Version: 1.0",
        "Content-Type: multipart/mixed; boundary=\"\(boundary)\"",
        "",
        "--\(boundary)",
        "Content-Type: text/plain; charset=utf-8",
        "",
        "Two attachments for the promise probe.",
        "",
    ]
    for attachment in attachments {
        lines += [
            "--\(boundary)",
            "Content-Type: \(attachment.type); name=\"\(attachment.name)\"",
            "Content-Disposition: attachment; filename=\"\(attachment.name)\"",
            "Content-Transfer-Encoding: base64",
            "",
            attachment.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]),
        ]
    }
    lines += ["--\(boundary)--", ""]
    return Data(lines.joined(separator: "\r\n").utf8)
}

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
write(photo("Probe A", from: .systemTeal, to: .systemIndigo), to: "Probe A.jpg", as: .jpeg)
write(photo("Probe B", from: .systemOrange, to: .systemPink), to: "Probe B.jpg", as: .jpeg)
write(photo("Probe C", from: .systemGreen, to: .systemBlue), to: "Probe C.heic", as: .heic)
try writeVideo(to: "Probe Video.mov", seconds: 15)
let plan = pngData(photo("Site Plan", from: .darkGray, to: .systemBrown))
try mailMessage(attachments: [
    ("Invoice 2026-10.pdf", "application/pdf", invoicePDF()),
    ("Site Plan.png", "image/png", plan),
]).write(to: output.appendingPathComponent("Probe Mail.eml"))
print("wrote test media to \(output.path)")
