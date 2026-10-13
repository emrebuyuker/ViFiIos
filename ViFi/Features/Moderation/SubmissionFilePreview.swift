import PDFKit
import SwiftUI

/// Previews a submission's pending files so an admin can review them before approving. Images are shown as a
/// vertical scroll of pages; a PDF in a scrolling PDF view. Files are loaded through `RemoteFileLoader` with the
/// same authorized download path the archive uses (an admin may read `pending/…`).
struct SubmissionFilePreview: View {
    let files: [SubmissionFileRef]
    let kind: ExamKind

    @Environment(AppEnvironment.self) private var environment

    private var urls: [URL] {
        files
            .sorted { $0.order < $1.order }
            .compactMap { StorageURL.canonical(storagePath: $0.storagePath, bucket: environment.storageBucket) }
    }

    var body: some View {
        Group {
            if urls.isEmpty {
                EmptyStateView(title: "Dosya yok", systemImage: "doc")
            } else if kind == .images {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                            RemoteFileImage(url: url)
                                .accessibilityIdentifier("moderation.preview.page.\(index)")
                        }
                    }
                    .padding()
                }
            } else if let url = urls.first {
                PDFFilePreview(url: url)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Dosyalar")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("moderation.preview")
    }
}

/// One submission page, downloaded and decoded through the file loader, with loading and failure states.
private struct RemoteFileImage: View {
    let url: URL

    @Environment(AppEnvironment.self) private var environment
    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(.rect(cornerRadius: 12, style: .continuous))
            } else if didFail {
                placeholder
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 220)
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            image = try await environment.fileLoader.image(from: url, maxPixelSize: 2200, speculative: false)
        } catch {
            didFail = true
        }
    }

    private var placeholder: some View {
        ContentUnavailableView("Görsel yüklenemedi", systemImage: "photo.badge.exclamationmark")
            .frame(maxWidth: .infinity, minHeight: 220)
    }
}

/// A submission's PDF, downloaded to a local file through the loader and shown in a scrolling PDF view.
private struct PDFFilePreview: View {
    let url: URL

    @Environment(AppEnvironment.self) private var environment
    @State private var document: PDFDocument?
    @State private var didFail = false

    var body: some View {
        Group {
            if let document {
                PDFKitView(document: document)
            } else if didFail {
                ContentUnavailableView("PDF yüklenemedi", systemImage: "doc.badge.exclamationmark")
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let localURL = try await environment.fileLoader.localFile(from: url, fileName: "submission-preview.pdf")
            if let loaded = PDFDocument(url: localURL) {
                document = loaded
            } else {
                didFail = true
            }
        } catch {
            didFail = true
        }
    }
}
