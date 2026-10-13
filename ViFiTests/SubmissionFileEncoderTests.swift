import Foundation
import Testing
import UIKit
@testable import ViFi

@Suite("SubmissionFileEncoder")
struct SubmissionFileEncoderTests {
    @MainActor
    private static func pngData(side: Int) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
        return image.pngData() ?? Data()
    }

    @Test("A valid image becomes a JPEG within the size limit")
    @MainActor
    func encodesToJPEG() async throws {
        let png = Self.pngData(side: 240)
        #expect(!png.isEmpty)

        let jpeg = try #require(await SubmissionFileEncoder.jpeg(from: png, maxBytes: ExamSubmission.maxFileBytes))

        #expect(!jpeg.isEmpty)
        #expect(jpeg.count <= ExamSubmission.maxFileBytes)
        #expect(jpeg.starts(with: [0xFF, 0xD8])) // JPEG start-of-image marker
    }

    @Test("Non-image data cannot be encoded")
    func rejectsNonImage() async {
        let result = await SubmissionFileEncoder.jpeg(from: Data([0, 1, 2, 3, 4]), maxBytes: ExamSubmission.maxFileBytes)
        #expect(result == nil)
    }

    @Test("An image that cannot fit under the limit returns nil")
    @MainActor
    func rejectsWhenOverLimit() async {
        let png = Self.pngData(side: 240)
        // A one-byte limit cannot hold any JPEG.
        let result = await SubmissionFileEncoder.jpeg(from: png, maxBytes: 1)
        #expect(result == nil)
    }
}
