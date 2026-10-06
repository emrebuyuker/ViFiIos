import PDFKit
import SwiftUI

/// A `PDFView` showing `document` as a continuous, vertically scrolling stack of pages
/// that fits the width and supports pinch to zoom.
struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument
    /// Called with the 0-based index of the page in view whenever it changes (`PDFViewPageChanged`).
    var onPageChange: (Int) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPageChange: onPageChange)
    }

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = .systemGroupedBackground
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.accessibilityIdentifier = "exam.pdf"
        context.coordinator.observePageChanges(of: pdfView)
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        context.coordinator.onPageChange = onPageChange
        guard pdfView.document !== document else { return }
        pdfView.document = document
        // Fit the new document's pages to the width again.
        pdfView.autoScales = true
    }

    static func dismantleUIView(_ pdfView: PDFView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        var onPageChange: (Int) -> Void
        private weak var pdfView: PDFView?

        init(onPageChange: @escaping (Int) -> Void) {
            self.onPageChange = onPageChange
        }

        func observePageChanges(of pdfView: PDFView) {
            self.pdfView = pdfView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pageDidChange),
                name: .PDFViewPageChanged,
                object: pdfView
            )
        }

        func stopObserving() {
            NotificationCenter.default.removeObserver(self, name: .PDFViewPageChanged, object: nil)
        }

        @objc private func pageDidChange() {
            // The notification can be posted while SwiftUI updates the view (a new document);
            // report on the next turn so the callback never mutates state during an update.
            Task { [weak self] in
                self?.reportCurrentPage()
            }
        }

        private func reportCurrentPage() {
            guard let pdfView, let document = pdfView.document, let page = pdfView.currentPage else { return }
            onPageChange(document.index(for: page))
        }
    }
}

#if DEBUG
#Preview {
    Group {
        if let url = ExamPreviewFixtures.samplePDFURL, let document = PDFDocument(url: url) {
            PDFKitView(document: document)
                .ignoresSafeArea(edges: .bottom)
        } else {
            ContentUnavailableView("Örnek PDF bulunamadı", systemImage: "doc.richtext")
        }
    }
    .environment(AppEnvironment.mock())
}
#endif
