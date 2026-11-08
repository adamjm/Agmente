//
//  ImageAttachment.swift
//  ACPCode
//
//  Image attachment model for including images in prompts.
//

import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
typealias UIImage = NSImage
#else
#error("Unsupported platform: requires UIKit or AppKit")
#endif

extension Image {
    init(platformImage: UIImage) {
#if canImport(UIKit)
        self.init(uiImage: platformImage)
#else
        self.init(nsImage: platformImage)
#endif
    }
}

#if canImport(AppKit)
private extension UIImage {
    var ag_cgImage: CGImage? {
        var proposedRect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }

    func ag_pngData() -> Data? {
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    func ag_jpegData(compressionQuality: CGFloat) -> Data? {
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation) else {
            return nil
        }
        return bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: compressionQuality]
        )
    }
}
#endif

/// Represents an image attachment ready to be sent in a prompt.
struct ImageAttachment: Identifiable, Equatable {
    let id: UUID
    let image: UIImage
    let mimeType: String
    let base64Data: String
    
    /// Original file size in bytes (before compression).
    let originalSize: Int
    
    /// Compressed size in bytes (base64 encoded).
    var compressedSize: Int {
        base64Data.count
    }
    
    /// Human-readable size string.
    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(compressedSize), countStyle: .file)
    }
    
    /// Creates a thumbnail for preview display.
    func thumbnail(maxSize: CGFloat = 80) -> UIImage {
        let scale = min(maxSize / image.size.width, maxSize / image.size.height, 1.0)
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

#if canImport(UIKit)
        UIGraphicsBeginImageContextWithOptions(newSize, false, 0.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let thumbnail = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return thumbnail
#else
        let thumbnail = UIImage(size: newSize)
        thumbnail.lockFocus()
        image.draw(
            in: CGRect(origin: .zero, size: newSize),
            from: CGRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1.0
        )
        thumbnail.unlockFocus()
        return thumbnail
#endif
    }
    
    static func == (lhs: ImageAttachment, rhs: ImageAttachment) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Image Processing

enum ImageProcessor {
    /// Maximum image dimension (width or height) before resizing.
    static let maxDimension: CGFloat = 1024
    
    /// JPEG compression quality for images.
    static let jpegQuality: CGFloat = 0.8
    
    /// Maximum number of attachments allowed per prompt.
    static let maxAttachments: Int = 5
    
    /// Creates an ImageAttachment from a UIImage, with optional resizing and compression.
    /// - Parameters:
    ///   - image: The source image.
    ///   - resize: Whether to resize large images.
    /// - Returns: An ImageAttachment ready for sending, or nil if encoding fails.
    static func processImage(_ image: UIImage, resize: Bool = true) -> ImageAttachment? {
        let originalData = pngData(from: image) ?? jpegData(from: image, compressionQuality: 1.0)
        let originalSize = originalData?.count ?? 0
        
        // Resize if needed
        let processedImage: UIImage
        if resize && (image.size.width > maxDimension || image.size.height > maxDimension) {
            processedImage = resizeImage(image, maxDimension: maxDimension)
        } else {
            processedImage = image
        }
        
        // Determine format and encode
        // Prefer JPEG for photos (smaller), PNG for images with transparency
        let (data, mimeType) = encodeImage(processedImage)
        
        guard let imageData = data else {
            return nil
        }
        
        let base64String = imageData.base64EncodedString()
        
        return ImageAttachment(
            id: UUID(),
            image: processedImage,
            mimeType: mimeType,
            base64Data: base64String,
            originalSize: originalSize
        )
    }
    
    /// Resizes an image to fit within the specified maximum dimension.
    private static func resizeImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let scale = min(maxDimension / image.size.width, maxDimension / image.size.height)
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

#if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
#else
        let resized = UIImage(size: newSize)
        resized.lockFocus()
        image.draw(
            in: CGRect(origin: .zero, size: newSize),
            from: CGRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1.0
        )
        resized.unlockFocus()
        return resized
#endif
    }
    
    /// Encodes an image to data with appropriate format detection.
    private static func encodeImage(_ image: UIImage) -> (Data?, String) {
        // Check if image has alpha channel (transparency)
        if hasAlphaChannel(image) {
            // Use PNG to preserve transparency
            return (pngData(from: image), "image/png")
        } else {
            // Use JPEG for smaller file size
            return (jpegData(from: image, compressionQuality: jpegQuality), "image/jpeg")
        }
    }
    
    /// Checks if an image has an alpha channel.
    private static func hasAlphaChannel(_ image: UIImage) -> Bool {
        guard let cgImage = cgImage(from: image) else { return false }
        let alphaInfo = cgImage.alphaInfo
        return alphaInfo == .first || alphaInfo == .last ||
               alphaInfo == .premultipliedFirst || alphaInfo == .premultipliedLast
    }

    private static func pngData(from image: UIImage) -> Data? {
#if canImport(UIKit)
        image.pngData()
#else
        image.ag_pngData()
#endif
    }

    private static func jpegData(from image: UIImage, compressionQuality: CGFloat) -> Data? {
#if canImport(UIKit)
        image.jpegData(compressionQuality: compressionQuality)
#else
        image.ag_jpegData(compressionQuality: compressionQuality)
#endif
    }

    private static func cgImage(from image: UIImage) -> CGImage? {
#if canImport(UIKit)
        image.cgImage
#else
        image.ag_cgImage
#endif
    }
}

// MARK: - ChatMessage Image Storage

/// Lightweight image data for display in chat history (thumbnail only).
struct ChatImageData: Identifiable, Equatable {
    let id: UUID
    let thumbnail: UIImage
    let mimeType: String
    
    /// Creates a ChatImageData from an ImageAttachment (for storing in chat history).
    init(from attachment: ImageAttachment) {
        self.id = attachment.id
        self.thumbnail = attachment.thumbnail(maxSize: 200) // Larger thumbnail for chat display
        self.mimeType = attachment.mimeType
    }
    
    static func == (lhs: ChatImageData, rhs: ChatImageData) -> Bool {
        lhs.id == rhs.id
    }
}
