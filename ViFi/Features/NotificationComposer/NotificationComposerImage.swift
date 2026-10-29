import Foundation
import Observation
import UIKit

/// The composer's campaign image: a picked photo, downsampled to `NotificationImage.maxPixelSize` and encoded as a
/// JPEG within `NotificationImage.maxBytes` (what the Storage rule and the server accept), with a preview. It is
/// uploaded only when the notification is sent (`NotificationComposerViewModel`).
@Observable
final class NotificationComposerImage {
    /// The encoded JPEG to upload; `nil` without an image.
    private(set) var jpeg: Data?
    private(set) var preview: UIImage?
    private(set) var isPreparing = false
    private(set) var errorMessage: String?

    /// Bumped by every pick and removal, so a slow encode of an earlier pick never replaces a later one.
    @ObservationIgnored private var generation = 0

    var hasImage: Bool { jpeg != nil }

    /// Replaces the image with `data` (any decodable image: HEIC, PNG, JPEG…). Returns whether it is usable; when
    /// it is not, the previous image stays and `errorMessage` says why.
    @discardableResult
    func prepare(from data: Data) async -> Bool {
        generation += 1
        let current = generation
        isPreparing = true
        errorMessage = nil
        let encoded = await SubmissionFileEncoder.jpeg(
            from: data,
            maxBytes: NotificationImage.maxBytes,
            maxPixelSize: NotificationImage.maxPixelSize
        )
        guard current == generation else { return false }
        isPreparing = false
        guard let encoded else {
            errorMessage = String(localized: "Bu görsel kullanılamıyor. Başka bir görsel seç.")
            return false
        }
        jpeg = encoded
        preview = UIImage(data: encoded)
        return true
    }

    /// The image could not be read from the photo library.
    func reportUnreadable() {
        errorMessage = String(localized: "Görsel yüklenemedi. Başka bir görsel seç.")
    }

    func remove() {
        generation += 1
        jpeg = nil
        preview = nil
        isPreparing = false
        errorMessage = nil
    }
}
