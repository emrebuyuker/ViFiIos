import Foundation
import Testing
@testable import ViFi

@Suite("StorageURL")
struct StorageURLTests {
    private static let bucket = "vifi-831a8.appspot.com"

    @Test("A storage path becomes the canonical download URL, with the path as one encoded segment")
    func canonicalURL() throws {
        let url = try #require(StorageURL.canonical(storagePath: "pdfs/exam.pdf", bucket: Self.bucket))

        #expect(url.absoluteString == "https://firebasestorage.googleapis.com/v0/b/vifi-831a8.appspot.com/o/pdfs%2Fexam.pdf?alt=media")
    }

    @Test("Image paths are encoded the same way")
    func imagePath() throws {
        let url = try #require(StorageURL.canonical(storagePath: "imagess/a1b2.jpg", bucket: Self.bucket))

        #expect(url.absoluteString == "https://firebasestorage.googleapis.com/v0/b/vifi-831a8.appspot.com/o/imagess%2Fa1b2.jpg?alt=media")
    }

    @Test("Spaces, Turkish letters and slashes are percent-encoded; dots are kept")
    func encodesSpecialCharacters() throws {
        let url = try #require(StorageURL.canonical(storagePath: "imagess/a bç.jpg", bucket: Self.bucket))

        #expect(url.absoluteString == "https://firebasestorage.googleapis.com/v0/b/vifi-831a8.appspot.com/o/imagess%2Fa%20b%C3%A7.jpg?alt=media")
    }

    @Test("A deeper path keeps every slash encoded as a single segment")
    func nestedPath() throws {
        let url = try #require(StorageURL.canonical(storagePath: "pending/uid-1/sub-2/file.pdf", bucket: Self.bucket))

        #expect(url.path(percentEncoded: true) == "/v0/b/vifi-831a8.appspot.com/o/pending%2Fuid-1%2Fsub-2%2Ffile.pdf")
    }

    @Test("The URL is accepted by the download layer as an object in the bucket, token-free")
    func roundTripsThroughDownloadLayer() throws {
        let url = try #require(StorageURL.canonical(storagePath: "imagess/a bç.jpg", bucket: Self.bucket))

        #expect(RemoteFileLoader.isFirebaseStorageURL(url))
        #expect(FirebaseRequestAuthorizer.isObject(url, inBucket: Self.bucket))
        // No token to strip, so the canonical form is the URL itself.
        #expect(RemoteFileLoader.canonicalURL(for: url) == url)
        #expect(!url.absoluteString.contains("token="))
        #expect(url.query() == "alt=media")
    }

    @Test("An empty path or bucket yields no URL", arguments: [
        ("", "vifi-831a8.appspot.com"),
        ("imagess/x.jpg", ""),
        ("", ""),
    ])
    func emptyInputs(path: String, bucket: String) {
        #expect(StorageURL.canonical(storagePath: path, bucket: bucket) == nil)
    }
}
