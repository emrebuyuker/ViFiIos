import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns an arbitrary picked image into a JPEG small enough to upload.
///
/// The Storage rules accept only `image/jpeg` (and `application/pdf`) up to 15 MiB, and a photo-library image
/// may be HEIC, PNG or a very large JPEG. This downsamples the longest side and steps the quality down until
/// the encoded JPEG fits, all off the main actor (ImageIO, no `UIImage`).
nonisolated enum SubmissionFileEncoder {
    /// Longest-side pixel limit a page is downsampled to before encoding (keeps big camera photos well under
    /// the size cap while staying readable).
    private static let maxPixelSize = 3000
    /// JPEG qualities tried in turn until the encoded size fits the limit.
    private static let qualitySteps: [CGFloat] = [0.8, 0.6, 0.45, 0.3]

    /// A JPEG rendering of `data` no larger than `maxBytes`, or `nil` when the data is not a decodable image or
    /// cannot be brought under the limit. Honors the source's EXIF orientation.
    @concurrent
    static func jpeg(from data: Data, maxBytes: Int) async -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        for quality in qualitySteps {
            guard let encoded = encode(image, quality: quality) else { continue }
            if encoded.count <= maxBytes {
                return encoded
            }
        }
        return nil
    }

    private static func encode(_ image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
