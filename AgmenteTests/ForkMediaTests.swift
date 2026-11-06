import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
import ACPClient
@testable import Agmente

/// T-36 (FR-37, NFR-13): oversized, wrong MIME, corrupt data and decompression bombs must be
/// refused or downsampled without crashing or exhausting memory.
struct ForkMediaTests {

    // MARK: Fixtures

    /// Solid grey image encoded with ImageIO. The bitmap is freed before this returns.
    private static func encode(width: Int, height: Int, type: UTType = .png) -> Data {
        let data = NSMutableData()
        autoreleasepool {
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            context.setFillColor(gray: 0.5, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let image = context.makeImage()!
            let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            precondition(CGImageDestinationFinalize(destination))
        }
        return data as Data
    }

    private static func base64(_ data: Data) -> String { data.base64EncodedString() }

    private static func refusal(_ result: Result<CGImage, ForkImageRefusal>) -> ForkImageRefusal? {
        if case .failure(let refusal) = result { return refusal }
        return nil
    }

    static func footprintForSampler() -> Int { footprint() }

    /// Current physical footprint in bytes.
    private static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    // MARK: Happy path

    @Test func smallPngDecodes() throws {
        let data = Self.encode(width: 64, height: 32)
        let image = try ForkImageDecoder.decode(base64: Self.base64(data), mimeType: "image/png").get()
        #expect(image.width == 64 && image.height == 32)
    }

    @Test func mimeParametersAndCaseAreNormalized() {
        let data = Self.encode(width: 8, height: 8)
        let result = ForkImageDecoder.decode(base64: Self.base64(data), mimeType: " IMAGE/PNG; charset=binary")
        #expect(Self.refusal(result) == nil)
    }

    @Test func jpegAndGifDecode() {
        for (type, mime) in [(UTType.jpeg, "image/jpeg"), (UTType.gif, "image/gif")] {
            let data = Self.encode(width: 16, height: 16, type: type)
            #expect(Self.refusal(ForkImageDecoder.decode(base64: Self.base64(data), mimeType: mime)) == nil, "\(mime)")
        }
    }

    // MARK: Refusals

    @Test func svgAndOtherMimeTypesAreRefused() {
        let svg = Data("<svg xmlns='http://www.w3.org/2000/svg'><script>alert(1)</script></svg>".utf8)
        for mime in ["image/svg+xml", "text/html", "application/pdf", "image/tiff", "image/bmp", "", "png"] {
            let result = ForkImageDecoder.decode(base64: Self.base64(svg), mimeType: mime)
            #expect(Self.refusal(result) == .mimeNotAllowed(ForkMediaLimits.normalizedMime(mime)), "\(mime)")
        }
    }

    @Test func declaredPngButJpegDataIsRefused() {
        let jpeg = Self.encode(width: 16, height: 16, type: .jpeg)
        #expect(Self.refusal(ForkImageDecoder.decode(base64: Self.base64(jpeg), mimeType: "image/png")) == .mimeMismatch)
    }

    @Test func allowedMimeWithNonImageDataIsRefused() {
        let text = Data("this is not an image".utf8)
        #expect(Self.refusal(ForkImageDecoder.decode(base64: Self.base64(text), mimeType: "image/png")) == .malformed)
    }

    @Test func invalidBase64AndEmptyDataAreRefused() {
        #expect(Self.refusal(ForkImageDecoder.decode(base64: "%%%not base64%%%", mimeType: "image/png")) == .malformed)
        #expect(Self.refusal(ForkImageDecoder.decode(base64: "", mimeType: "image/png")) == .malformed)
    }

    @Test func truncatedAndCorruptPngDoNotCrash() {
        let good = Self.encode(width: 200, height: 200)
        let truncated = good.prefix(good.count / 2)
        _ = ForkImageDecoder.decode(base64: Self.base64(Data(truncated)), mimeType: "image/png")

        var corrupt = good
        for index in stride(from: 40, to: corrupt.count, by: 7) { corrupt[index] ^= 0xFF }
        _ = ForkImageDecoder.decode(base64: Self.base64(corrupt), mimeType: "image/png")

        let header = Data(good.prefix(8))
        #expect(Self.refusal(ForkImageDecoder.decode(base64: Self.base64(header), mimeType: "image/png")) != nil)
    }

    @Test func base64OverLimitIsRefusedBeforeDecoding() {
        let tooLong = String(repeating: "A", count: ForkMediaLimits.maxBase64Characters + 4)
        #expect(Self.refusal(ForkImageDecoder.decode(base64: tooLong, mimeType: "image/png")) == .tooLarge)
    }

    @Test func decodedDataOverTwentyMiBIsRefused() {
        // Just under the base64 length cap but decodes to more than 20 MiB is impossible by
        // construction; check the byte check directly with data one byte over the limit.
        let over = Data(repeating: 0, count: ForkMediaLimits.maxDecodedBytes + 1)
        #expect(Self.refusal(ForkImageDecoder.decode(base64: Self.base64(over), mimeType: "image/png")) == .tooLarge)
    }

    // MARK: Decompression bombs

    @Test func hugePixelCountIsRefusedWithoutDecoding() {
        // 12000 x 9000 = 108 MP of solid grey compresses to a few hundred KB.
        let bomb = Self.encode(width: 12_000, height: 9_000)
        #expect(bomb.count < 5 * 1024 * 1024)
        let before = Self.footprint()
        let result = ForkImageDecoder.decode(base64: Self.base64(bomb), mimeType: "image/png")
        let growth = Self.footprint() - before
        #expect(Self.refusal(result) == .dimensionsTooLarge)
        #expect(growth < 50 * 1024 * 1024, "growth \(growth)")
    }

    @Test func extremeSideLengthIsRefused() {
        let wide = Self.encode(width: 30_000, height: 4)
        #expect(Self.refusal(ForkImageDecoder.decode(base64: Self.base64(wide), mimeType: "image/png")) == .dimensionsTooLarge)
    }

    // MARK: T-36

    @Test func fiftyMegapixelPngIsDownsampledWithinMemoryBudget() throws {
        let data = Self.encode(width: 8_000, height: 6_250) // 50 MP
        let encoded = Self.base64(data)
        let baseline = Self.footprint()

        let sampler = PeakSampler(baseline: baseline)
        let result = ForkImageDecoder.decode(base64: encoded, mimeType: "image/png")
        let peak = sampler.finish()

        let image = try result.get()
        let increase = peak - baseline
        print("T-36 50MP PNG: encoded \(data.count) bytes, output \(image.width)x\(image.height), peak increase \(increase / 1_048_576) MiB")
        #expect(max(image.width, image.height) <= 4096)
        #expect(max(image.width, image.height) <= ForkMediaLimits.maxDisplayPixelSize)
        #expect(increase <= 100 * 1024 * 1024, "peak increase \(increase)")
    }

    // MARK: Ingest from content blocks

    @Test func ingestShowsPlaceholderForRefusedImage() {
        let item = ForkMediaIngest.item(for: .image(mimeType: "image/svg+xml", data: "PHN2Zz4=", uri: nil))
        guard case .placeholder(_, let detail) = item.content else { Issue.record("expected placeholder"); return }
        #expect(detail.contains("not allowed"))
    }

    @Test func ingestRendersResourceImageBlobAndPlaceholdersOtherResources() {
        let png = Self.base64(Self.encode(width: 10, height: 10))
        let image = ForkMediaIngest.item(for: .resource(uri: "file:///a.png", mimeType: "image/png", blob: png, text: nil))
        guard case .image = image.content else { Issue.record("expected image"); return }

        let text = ForkMediaIngest.item(for: .resource(uri: "file:///a.txt", mimeType: "text/plain", blob: nil, text: "hi"))
        guard case .placeholder = text.content else { Issue.record("expected placeholder"); return }
    }

    @Test func resourceLinkIsALinkRowAndNeverLoads() {
        let item = ForkMediaIngest.item(for: .resourceLink(
            uri: "https://example.com/\u{0007}x.png", name: "x.png", title: nil, mimeType: "image/png", size: 5
        ))
        guard case .link(let title, let uri, _) = item.content else { Issue.record("expected link"); return }
        #expect(title == "x.png")
        #expect(!uri.contains("\u{0007}"))
    }

    @Test func mapperEmitsMediaEntryForMediaSegment() {
        let item = ForkMediaIngest.item(for: .resourceLink(uri: "https://e.com/a", name: nil, title: nil, mimeType: nil, size: nil))
        let message = ChatMessage(
            role: .assistant, content: "", isStreaming: false,
            segments: [AssistantSegment(kind: .message, text: item.fallbackText, media: item)]
        )
        let entries = ChatEntryMapper().entries(from: [message])
        #expect(entries.map(\.kind) == [.media])
        #expect(entries.first?.media == item)
    }
}

/// Polls the process footprint on a background thread and keeps the highest value.
private final class PeakSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Int
    private var stopped = false

    init(baseline: Int) {
        peak = baseline
        let thread = Thread { [self] in
            while true {
                lock.lock()
                let done = stopped
                peak = max(peak, ForkMediaTests.footprintForSampler())
                lock.unlock()
                if done { return }
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
        thread.start()
    }

    func finish() -> Int {
        lock.lock()
        stopped = true
        peak = max(peak, ForkMediaTests.footprintForSampler())
        let value = peak
        lock.unlock()
        return value
    }
}
