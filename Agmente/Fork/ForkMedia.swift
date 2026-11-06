import Foundation
import CoreGraphics
import ImageIO
import ACPClient

// PLAN 5.2 / FR-37 / NFR-13: safe handling of agent-supplied images.
//
// Rules, in order. Each one refuses before the next, more expensive step runs:
//   1. MIME allow-list (png, jpeg, gif, webp, heic, heif). SVG and everything else is refused.
//   2. Base64 text length limit, checked before any decoding (decoded size <= 20 MiB).
//   3. Base64 decode into Data (malformed -> refused).
//   4. ImageIO header read only: type must be allowed and match the declared MIME, pixel
//      dimensions are read without decoding, and a source over `maxSourcePixels` is refused
//      (decompression bomb).
//   5. Display copy made with a thumbnail request capped at `maxDisplayPixelSize`. The full
//      size image is never decoded for display.

/// Why an image was not shown. `message` is the visible placeholder text.
enum ForkImageRefusal: Error, Equatable {
    case mimeNotAllowed(String)
    case tooLarge
    case malformed
    case dimensionsTooLarge
    case mimeMismatch

    var message: String {
        switch self {
        case .mimeNotAllowed(let mime):
            return mime.isEmpty ? "Image type not allowed" : "Image type not allowed (\(ForkMediaLimits.printable(mime)))"
        case .tooLarge: return "Image too large to show"
        case .malformed: return "Image could not be decoded"
        case .dimensionsTooLarge: return "Image dimensions too large to show"
        case .mimeMismatch: return "Image data does not match its declared type"
        }
    }
}

enum ForkMediaLimits {
    /// NFR-13: refuse image data over 20 MiB (decoded bytes).
    static let maxDecodedBytes = 20 * 1024 * 1024
    /// Base64 length that decodes to at most `maxDecodedBytes`.
    static let maxBase64Characters = (maxDecodedBytes / 3 + 1) * 4
    /// NFR-13 allows 4096. The display copy is capped lower to keep bitmap memory near 16 MB.
    static let maxDisplayPixelSize = 2048
    /// Source images over this many pixels are refused without decoding (decompression bomb).
    static let maxSourcePixels = 100_000_000
    static let maxSourceSide = 20_000

    static let allowedMimeTypes: [String: Set<String>] = [
        "image/png": ["public.png"],
        "image/jpeg": ["public.jpeg"],
        "image/jpg": ["public.jpeg"],
        "image/gif": ["com.compuserve.gif"],
        "image/webp": ["org.webmproject.webp"],
        "image/heic": ["public.heic", "public.heif"],
        "image/heif": ["public.heic", "public.heif"],
    ]

    static func normalizedMime(_ mime: String) -> String {
        mime.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    }

    /// Strip control characters and cut long text, for strings that come from the agent.
    static func printable(_ text: String, limit: Int = 120) -> String {
        let cleaned = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let string = String(String.UnicodeScalarView(cleaned))
        return string.count > limit ? String(string.prefix(limit)) + "…" : string
    }
}

enum ForkImageDecoder {
    /// Validates and downsamples base64 image data. Never throws and never traps on bad input.
    static func decode(base64: String, mimeType: String) -> Result<CGImage, ForkImageRefusal> {
        let mime = ForkMediaLimits.normalizedMime(mimeType)
        guard let allowedTypes = ForkMediaLimits.allowedMimeTypes[mime] else {
            return .failure(.mimeNotAllowed(mime))
        }
        guard base64.utf8.count <= ForkMediaLimits.maxBase64Characters else {
            return .failure(.tooLarge)
        }
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), !data.isEmpty else {
            return .failure(.malformed)
        }
        guard data.count <= ForkMediaLimits.maxDecodedBytes else {
            return .failure(.tooLarge)
        }
        return downsample(data: data, allowedTypes: allowedTypes)
    }

    static func downsample(
        data: Data,
        allowedTypes: Set<String>,
        maxPixelSize: Int = ForkMediaLimits.maxDisplayPixelSize
    ) -> Result<CGImage, ForkImageRefusal> {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return .failure(.malformed)
        }
        guard let type = CGImageSourceGetType(source) as String? else {
            return .failure(.malformed)
        }
        guard allowedTypes.contains(type) else {
            // A known image type that is not the declared one, or not an allowed type at all.
            return .failure(.mimeMismatch)
        }
        guard CGImageSourceGetCount(source) >= 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            return .failure(.malformed)
        }
        guard width <= ForkMediaLimits.maxSourceSide,
              height <= ForkMediaLimits.maxSourceSide,
              width.multipliedReportingOverflow(by: height).overflow == false,
              width * height <= ForkMediaLimits.maxSourcePixels else {
            return .failure(.dimensionsTooLarge)
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return .failure(.malformed)
        }
        return .success(image)
    }
}

/// What the chat shows for one media block. Holds only a downsampled bitmap, never the source data.
struct ForkMediaItem: Identifiable, Hashable {
    enum Content {
        case image(CGImage)
        /// A visible placeholder: refused image, or a resource the app does not render.
        case placeholder(title: String, detail: String)
        /// A `resource_link`. Shown as a row; never fetched (fetching is gateway work, PLAN 5.3).
        case link(title: String, uri: String, detail: String)
    }

    let id = UUID()
    let content: Content

    static func == (lhs: ForkMediaItem, rhs: ForkMediaItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Text kept in the segment, so a restored chat (media is not persisted) still says what was there.
    var fallbackText: String {
        switch content {
        case .image: return "[image]"
        case .placeholder(let title, _): return "[\(title)]"
        case .link(let title, let uri, _): return "[\(title)] \(uri)"
        }
    }

    /// Display size for an image, fitted into a box. Zero for non-image content.
    func fittedSize(maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        guard case .image(let image) = content, image.width > 0, image.height > 0 else { return .zero }
        let scale = min(maxWidth / CGFloat(image.width), maxHeight / CGFloat(image.height), 1)
        return CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    }
}

enum ForkMediaIngest {
    static func item(for block: ACPMediaBlock) -> ForkMediaItem {
        switch block {
        case .image(let mimeType, let data, _):
            return imageItem(base64: data, mimeType: mimeType)
        case .resource(let uri, let mimeType, let blob, _):
            let mime = ForkMediaLimits.normalizedMime(mimeType ?? "")
            if let blob, mime.hasPrefix("image/") {
                return imageItem(base64: blob, mimeType: mime)
            }
            let name = uri.map { ForkMediaLimits.printable($0) } ?? "resource"
            return ForkMediaItem(content: .placeholder(
                title: "Resource",
                detail: mime.isEmpty ? name : "\(name) (\(ForkMediaLimits.printable(mime)))"
            ))
        case .resourceLink(let uri, let name, let title, let mimeType, let size):
            var detail: [String] = []
            if let mimeType, !mimeType.isEmpty { detail.append(ForkMediaLimits.printable(mimeType)) }
            if let size { detail.append("\(size) bytes") }
            let label = ForkMediaLimits.printable(title ?? name ?? uri)
            return ForkMediaItem(content: .link(
                title: label,
                uri: ForkMediaLimits.printable(uri, limit: 300),
                detail: detail.joined(separator: ", ")
            ))
        }
    }

    private static func imageItem(base64: String, mimeType: String) -> ForkMediaItem {
        switch ForkImageDecoder.decode(base64: base64, mimeType: mimeType) {
        case .success(let image):
            return ForkMediaItem(content: .image(image))
        case .failure(let refusal):
            return ForkMediaItem(content: .placeholder(title: "Image", detail: refusal.message))
        }
    }
}
