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

    // PDFView's own layer is the flagged ancestor of its page views and of the tiles PDFKit creates while scrolling
    // and zooming, so one flag at creation covers every page.
    func makeUIView(context: Context) -> CaptureShieldedView<ExamPDFView> {
        let pdfView = ExamPDFView()
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = .systemGroupedBackground  // opaque: covers the capture explanation
                pdfView.document = document
        pdfView.applyExtractionPolicy()
        pdfView.autoScales = true
        pdfView.accessibilityIdentifier = "exam.pdf"  // back on the PDF view: nothing hides its subtree any more
        context.coordinator.observePageChanges(of: pdfView)
        return CaptureShieldedView(content: pdfView)
    }

    func updateUIView(_ uiView: CaptureShieldedView<ExamPDFView>, context: Context) {
        context.coordinator.onPageChange = onPageChange
        guard uiView.content.document !== document else { return }
        uiView.content.document = document  // same flagged layer, so the new file's pages are covered too
        uiView.content.applyExtractionPolicy()
        uiView.content.autoScales = true
    }

    static func dismantleUIView(_ uiView: CaptureShieldedView<ExamPDFView>, coordinator: Coordinator) {
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

/// A `PDFView` whose page text cannot leave the app while `blocksContentExtraction` is on: no touch selection
/// (including Live Text on scanned pages), no edit menu, no Copy/Share/Translate/Look Up, no drag, no Find.
/// Scrolling, pinch zoom and double-tap zoom keep working, and VoiceOver still reads the page.
final class ExamPDFView: PDFView {
    var blocksContentExtraction = true {
        didSet { applyExtractionPolicy() }
    }

    /// Markup mode also turns off PDFView's own double-tap zoom; this recognizer stands in for it while protected.
    private let zoomTap = UITapGestureRecognizer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        zoomTap.numberOfTapsRequired = 2
        zoomTap.addTarget(self, action: #selector(zoomOnDoubleTap(_:)))
        addGestureRecognizer(zoomTap)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(selectionDidChange),
            name: .PDFViewSelectionChanged,
            object: self
        )
        applyExtractionPolicy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Edit actions

    /// Standard actions that move selected text out, or select all of it first (hardware keyboard Cmd-A).
    private static let blockedActions: Set<Selector> = [
        #selector(UIResponderStandardEditActions.copy(_:)),
        #selector(UIResponderStandardEditActions.cut(_:)),
        #selector(UIResponderStandardEditActions.selectAll(_:)),
        #selector(UIResponderStandardEditActions.printContent(_:)),
        #selector(UIResponderStandardEditActions.export(_:)),
        #selector(UIResponderStandardEditActions.find(_:)),
        #selector(UIResponderStandardEditActions.findAndReplace(_:)),
        #selector(UIResponderStandardEditActions.useSelectionForFind(_:)),
    ]
    /// Text-service actions matched by name: `share:`/`_share:`, `_translate:`, `_define:`, `_lookup:`,
    /// `findSelected:`, `_accessibilitySpeak:`, `showWritingTools:`.
    private static let blockedActionFragments = ["share", "translate", "define", "lookup", "search", "find", "speak", "writing"]

    /// Only consulted for actions whose responder-chain target is this view (copy:, selectAll:, _lookup:, …).
    /// PDFKit's internal text view is the first responder and answers share/translate/define itself, so those are
    /// closed by markup mode (no selection) and by the empty edit menu below.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard blocksContentExtraction else { return super.canPerformAction(action, withSender: sender) }
        let name = NSStringFromSelector(action).lowercased()
        let extracts = Self.blockedActions.contains(action) || Self.blockedActionFragments.contains { name.contains($0) }
        return !extracts && super.canPerformAction(action, withSender: sender)
    }

    /// Empties the edit menu (`UIMenuSystem.context`), including items a later iOS adds (Writing Tools, Speak, …).
    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard blocksContentExtraction, builder.system == .context else { return }
        builder.replaceChildren(ofMenu: .root) { _ in [] }
    }

    // MARK: - Policy

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyExtractionPolicy()  // PDFKit adds some interactions only once it is in a window
    }

    /// Safety net: a selection that still appears (assistive input, a future gesture) is dropped at once.
    @objc private func selectionDidChange() {
        guard blocksContentExtraction, let text = currentSelection?.string, !text.isEmpty else { return }
        clearSelection()
    }

    /// Re-applies the lock. Call it after assigning a new `document` (new page views bring new drag interactions).
    /// `document` is deliberately not overridden: PDFKit reads it on background threads while analyzing pages, and an
    /// override of a MainActor-isolated class traps on the isolation check (found by the PDF UI test).
    func applyExtractionPolicy() {
        // PDFView.h: in markup mode PDFView no longer handles the gestures for text selection (Live Text included).
        isInMarkupMode = blocksContentExtraction
        zoomTap.isEnabled = blocksContentExtraction
        if blocksContentExtraction {
            isFindInteractionEnabled = false
            clearSelection()
        }
        Self.setDragInteractions(enabled: !blocksContentExtraction, in: self)
    }

    private static func setDragInteractions(enabled: Bool, in view: UIView) {
        for case let drag as UIDragInteraction in view.interactions {
            drag.isEnabled = enabled
        }
        for subview in view.subviews {
            setDragInteractions(enabled: enabled, in: subview)
        }
    }

    // MARK: - Double-tap zoom

    /// Zooms in 2.5× around the tapped point, or back to fit-to-width when already zoomed in.
    @objc private func zoomOnDoubleTap(_ tap: UITapGestureRecognizer) {
        let fit = scaleFactorForSizeToFit
        guard scaleFactor < fit * 1.05 else {
            autoScales = true
            return
        }
        let location = tap.location(in: self)
        guard let page = page(for: location, nearest: true) else { return }
        let pagePoint = convert(location, to: page)
        let target = min(fit * 2.5, maxScaleFactor)
        scaleFactor = target
        // Keep the tapped point under the finger: the destination is the view's top-left corner in page space,
        // whose y axis grows upwards.
        let topLeft = CGPoint(x: pagePoint.x - location.x / target, y: pagePoint.y + location.y / target)
        go(to: PDFDestination(page: page, at: topLeft))
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
