import Foundation

/// Builds the canonical Firebase Storage download URL for an object stored at a `storagePath`
/// (e.g. `imagess/<uuid>.jpg`).
///
/// The archive stores the stable `storagePath` rather than a download URL whose token is revoked
/// (see CLAUDE.md); the client reconstructs the URL here. The result carries no download token:
/// `RemoteFileLoader` adds the user's ID token and App Check header and serves it from cache.
///
/// Format: `https://firebasestorage.googleapis.com/v0/b/<bucket>/o/<url-encoded path>?alt=media`, where
/// the whole object path is one percent-encoded segment ("/" → "%2F"), exactly as Firebase encodes object
/// names. Pure and side-effect free, so it is unit-testable.
nonisolated enum StorageURL {
    /// The canonical download URL for the object at `storagePath` in `bucket`, or `nil` when either is empty
    /// or the path cannot be encoded. `storagePath` is a bucket-relative object path, without a leading slash.
    static func canonical(storagePath: String, bucket: String) -> URL? {
        guard !storagePath.isEmpty, !bucket.isEmpty,
              let encodedPath = storagePath.addingPercentEncoding(withAllowedCharacters: objectPathAllowed) else {
            return nil
        }
        return URL(string: "https://\(RemoteFileLoader.firebaseStorageHost)/v0/b/\(bucket)/o/\(encodedPath)?alt=media")
    }

    /// Characters left unescaped in an object path: the RFC 3986 unreserved set. Everything else — crucially
    /// "/" → "%2F", plus spaces (%20) and non-ASCII (UTF-8 percent-encoded) — is escaped, so the whole path
    /// becomes a single URL segment the way Firebase Storage encodes object names.
    private static let objectPathAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()
}
