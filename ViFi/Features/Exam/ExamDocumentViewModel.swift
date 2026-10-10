import Foundation
import Observation
import OSLog

/// Loads the files of one exam for a viewer screen and records the visit.
///
/// Shared by `ExamImagesView` and `PDFExamView`; the screens own their file downloads,
/// this model owns the document, the recents entry and the analytics events.
@Observable
final class ExamDocumentViewModel {
    let path: ArchivePath
    private(set) var state: Loadable<ExamDocument> = .loading

    @ObservationIgnored private let repository: any ArchiveRepository
    @ObservationIgnored private let recents: RecentExamsStore
    @ObservationIgnored private let analytics: any AnalyticsTracking
    @ObservationIgnored private var isFetching = false
    @ObservationIgnored private var hasRecordedVisit = false

    init(
        path: ArchivePath,
        repository: any ArchiveRepository,
        recents: RecentExamsStore,
        analytics: any AnalyticsTracking
    ) {
        self.path = path
        self.repository = repository
        self.recents = recents
        self.analytics = analytics
    }

    /// The exam name, available before the document loads (navigation title).
    var title: String { path.name ?? "" }

    /// "University › Lesson": where the exam comes from.
    var subtitle: String {
        [path.components.first, path.components.dropLast().last]
            .compactMap { $0 }
            .joined(separator: " › ")
    }

    var document: ExamDocument? { state.value }

    /// Fetches the exam's files.
    ///
    /// A document that is already on screen stays visible while reloading, and when the reload fails.
    /// The visit is recorded in recents and analytics once, after the first successful load.
    func load() async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }

        if state.value == nil {
            state = .loading
        }
        do {
            let document = try await repository.document(at: path)
            state = .loaded(document)
            recordVisitIfNeeded(of: document)
        } catch {
            handleLoadFailure(error)
        }
    }

    /// Loads unless a document is already available. For `.task`, which runs again on every appearance.
    func loadIfNeeded() async {
        guard state.value == nil else { return }
        await load()
    }

    // MARK: - Private

    private func recordVisitIfNeeded(of document: ExamDocument) {
        guard !hasRecordedVisit else { return }
        hasRecordedVisit = true
        recents.record(path: path, kind: document.kind)
        analytics.track(.examOpened(kind: document.kind))
    }

    private func handleLoadFailure(_ error: any Error) {
        // Leaving the screen cancels the load: keep `.loading` so the next appearance retries.
        guard !Task.isCancelled, !(error is CancellationError) else { return }

        let location = path.components.joined(separator: "/")
        Logger.archive.error("Loading exam \(location, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        if state.value == nil {
            state = .failed(message: error.userMessage)
        }
    }
}

// MARK: - File names

extension ExamDocument {
    /// "2018 VİZE.pdf", or "2018 VİZE - Dosya 2.pdf" when the exam has several PDFs.
    /// Gives the cached download a readable name on disk.
    func pdfFileName(at index: Int) -> String {
        guard fileURLs.count > 1 else { return fileNameStem + ".pdf" }
        return String(localized: "\(fileNameStem) - Dosya \(index + 1)") + ".pdf"
    }

    /// The title without characters that are path separators on iOS or on disk.
    private var fileNameStem: String {
        let stem = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stem.isEmpty ? String(localized: "Sınav") : stem
    }
}

// MARK: - Preview fixtures

#if DEBUG
/// Exams of the mock archive and the bundled sample files, for SwiftUI previews of the viewers.
enum ExamPreviewFixtures {
    static let imagesExamPath = ArchivePath(components: [
        "BOZOK ÜNİVERSİTESİ", "MÜHENDİSLİK MİMARLIK FAKÜLTESİ", "BİLGİSAYAR MÜHENDİSLİĞİ",
        "MÜHENDİSLİK MATEMATİĞİ", "2019 FİNAL",
    ])

    static let pdfExamPath = ArchivePath(components: [
        "BOZOK ÜNİVERSİTESİ", "MÜHENDİSLİK MİMARLIK FAKÜLTESİ", "BİLGİSAYAR MÜHENDİSLİĞİ",
        "MÜHENDİSLİK MATEMATİĞİ", "2018 VİZE",
    ])

    static var imagesDocument: ExamDocument {
        ExamDocument(
            path: imagesExamPath,
            kind: .images,
            fileURLs: (1...3).compactMap { Bundle.main.url(forResource: "sample-page-\($0)", withExtension: "jpg") }
        )
    }

    static var samplePDFURL: URL? {
        Bundle.main.url(forResource: "sample-exam", withExtension: "pdf")
    }
}
#endif
