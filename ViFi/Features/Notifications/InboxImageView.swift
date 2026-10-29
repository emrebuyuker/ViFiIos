import SwiftUI
import UIKit

/// A notification's campaign image in the inbox: downloaded by its Storage path with the user's credentials
/// (`StorageURL` + `RemoteFileLoader`, ID token and App Check; images are never public), at a bounded height, with
/// a placeholder while it loads or when it cannot be loaded. On sample data it shows a bundled picture instead, so
/// mock runs never touch the network.
struct InboxImageView: View {
    let storagePath: String
    let notificationId: String

    @Environment(AppEnvironment.self) private var environment
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 160
    @State private var image: Loadable<UIImage> = .loading

    /// Images are at most 1600 px on their long side; this is plenty for a list row.
    private static let maxPixelSize: CGFloat = 1200

    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .frame(height: min(height, 280))
            .clipShape(.rect(cornerRadius: 12))
            .accessibilityElement()
            .accessibilityLabel("Bildirim görseli")
            .accessibilityAddTraits(.isImage)
            .accessibilityIdentifier("inbox.row.\(notificationId).image")
            .task(id: storagePath) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch image {
        case let .loaded(image):
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: min(height, 280))
                .clipped()
        case .loading:
            placeholder { ProgressView() }
        case .failed:
            placeholder {
                Image(systemName: "photo")
                    .font(.title)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func placeholder(@ViewBuilder _ symbol: () -> some View) -> some View {
        Rectangle()
            .fill(Color(.tertiarySystemFill))
            .overlay(content: symbol)
    }

    private func load() async {
        guard let url = Self.url(for: storagePath, bucket: environment.storageBucket) else {
            image = .failed(message: "")
            return
        }
        do {
            image = .loaded(try await environment.fileLoader.image(from: url, maxPixelSize: Self.maxPixelSize))
        } catch is CancellationError {
            // The row scrolled away; `.task` loads it again when it comes back.
        } catch {
            image = .failed(message: error.userMessage)
        }
    }

    /// Where the image is downloaded from: the app's own bucket, or a bundled sample on sample data.
    static func url(for storagePath: String, bucket: String) -> URL? {
        guard NotificationImage.isValidStoragePath(storagePath) else { return nil }
        #if DEBUG
        if AppEnvironment.usesMockData() {
            return Bundle.main.url(forResource: "sample-page-1", withExtension: "jpg")
                ?? Bundle.main.url(forResource: "sample-page-1", withExtension: "jpg", subdirectory: "SampleExams")
        }
        #endif
        return StorageURL.canonical(storagePath: storagePath, bucket: bucket)
    }
}
