import PhotosUI
import SwiftUI

// The composer's attachments: the campaign image and the exam an "exam" action opens.

// MARK: - Image

/// An optional image shown on the notification (the push and the inbox card): picked from the photo library,
/// downsampled and encoded as a JPEG of at most 1 MB, previewed, and uploaded only when the notification is sent.
struct NotificationComposerImageSection: View {
    let viewModel: NotificationComposerViewModel

    @State private var selection: PhotosPickerItem?
    @ScaledMetric(relativeTo: .body) private var previewHeight: CGFloat = 160

    private var image: NotificationComposerImage { viewModel.image }

    var body: some View {
        Section {
            if let preview = image.preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: min(previewHeight, 280))
                    .clipShape(.rect(cornerRadius: 12))
                    .accessibilityLabel("Seçilen görsel")
                    .accessibilityIdentifier("notificationComposer.imagePreview")
            }
            // Read on the main actor: the picker's label closure is `Sendable`.
            let hasImage = image.hasImage
            HStack(spacing: 12) {
                PhotosPicker(selection: $selection, matching: .images, photoLibrary: .shared()) {
                    Label(hasImage ? "Görseli Değiştir" : "Görsel Seç", systemImage: "photo.on.rectangle")
                }
                .accessibilityIdentifier("notificationComposer.imagePicker")
                if image.isPreparing {
                    Spacer()
                    ProgressView()
                        .accessibilityLabel("Görsel hazırlanıyor")
                }
            }
            if image.hasImage {
                Button("Görseli Kaldır", systemImage: "trash", role: .destructive) {
                    selection = nil
                    viewModel.removeImage()
                }
                .accessibilityIdentifier("notificationComposer.imageRemove")
            }
            if let message = image.errorMessage {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("notificationComposer.imageError")
            }
        } header: {
            Text("Görsel")
        } footer: {
            Text("İsteğe bağlı. Bildirimde ve bildirim sayfasında görünür; en fazla 1 MB JPEG'e küçültülür.")
        }
        .disabled(viewModel.isWorking)
        .animation(.smooth, value: image.hasImage)
        .onChange(of: selection) { _, item in
            guard let item else { return }
            Task { await load(item) }
        }
    }

    private func load(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            image.reportUnreadable()
            return
        }
        await viewModel.setImage(from: data)
    }
}

// MARK: - Exam

/// The "Sınav" action's target: the picked exam (with where it is in the archive) and a button to pick one.
struct NotificationComposerExamRow: View {
    @Bindable var viewModel: NotificationComposerViewModel

    @Environment(AppEnvironment.self) private var environment
    @State private var isPicking = false

    var body: some View {
        Button {
            isPicking = true
        } label: {
            LabeledContent("Sınav") {
                Text(viewModel.selectedExam?.name ?? String(localized: "Seç"))
                    .multilineTextAlignment(.trailing)
            }
        }
        .accessibilityIdentifier("notificationComposer.exam")
        .sheet(isPresented: $isPicking) {
            NotificationExamPickerView(repository: environment.repository) { exam in
                viewModel.selectedExam = exam
            }
        }

        if let exam = viewModel.selectedExam {
            Text(exam.path.displayNames.dropLast().joined(separator: " › "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("notificationComposer.examPath")
        }
    }
}
