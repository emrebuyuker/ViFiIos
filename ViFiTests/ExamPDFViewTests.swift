import PDFKit
import Testing
import UIKit
@testable import ViFi

/// The PDF text lock: with `blocksContentExtraction` on, page text cannot leave the app.
@MainActor
@Suite("ExamPDFView")
struct ExamPDFViewTests {
    @Test("Text selection is closed at the source: markup mode, no Find, double-tap zoom stand-in")
    func lockIsApplied() {
        let view = ExamPDFView()

        #expect(view.blocksContentExtraction)
        #expect(view.isInMarkupMode)
        #expect(!view.isFindInteractionEnabled)
        #expect(view.gestureRecognizers?.contains { ($0 as? UITapGestureRecognizer)?.numberOfTapsRequired == 2 } == true)
    }

    @Test("The lock survives a document change")
    func lockSurvivesDocumentChange() {
        let view = ExamPDFView()
        view.document = PDFDocument()
        view.applyExtractionPolicy()

        #expect(view.isInMarkupMode)
        #expect(!view.isFindInteractionEnabled)
    }

    @Test("Extracting actions are refused, zooming is not")
    func actionFilter() {
        let view = ExamPDFView()
        let extracting: [Selector] = [
            #selector(UIResponderStandardEditActions.copy(_:)),
            #selector(UIResponderStandardEditActions.selectAll(_:)),
            #selector(UIResponderStandardEditActions.find(_:)),
            NSSelectorFromString("_share:"),
            NSSelectorFromString("_translate:"),
            NSSelectorFromString("_define:"),
            NSSelectorFromString("_lookup:"),
            NSSelectorFromString("showWritingTools:"),
        ]
        for action in extracting {
            #expect(!view.canPerformAction(action, withSender: nil), "\(action) must be refused")
        }
        #expect(view.canPerformAction(#selector(PDFView.zoomIn(_:)), withSender: nil))
    }

    @Test("Turning the lock off restores PDFKit's own behavior")
    func lockCanBeLifted() {
        let view = ExamPDFView()
        view.blocksContentExtraction = false

        #expect(!view.isInMarkupMode)
        #expect(view.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil)
            == view.superCanPerformCopy)
    }
}

private extension ExamPDFView {
    /// What a plain `PDFView` answers for Copy with nothing selected.
    var superCanPerformCopy: Bool {
        PDFView().canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil)
    }
}
