import SwiftUI

extension ArchiveLevel {
    /// Title of a list of entries of this level.
    var listTitle: LocalizedStringResource {
        switch self {
        case .university: "Üniversiteler"
        case .faculty: "Fakülteler"
        case .department: "Bölümler"
        case .lesson: "Dersler"
        case .exam: "Sınavlar"
        }
    }

    var symbolName: String {
        switch self {
        case .university: "building.columns.fill"
        case .faculty: "graduationcap.fill"
        case .department: "books.vertical.fill"
        case .lesson: "book.closed.fill"
        case .exam: "doc.text.fill"
        }
    }

    /// "5 fakülte" — the number of children of an entry of this level.
    func childCountText(_ count: Int) -> String {
        switch self {
        case .university: String(localized: "\(count) fakülte")
        case .faculty: String(localized: "\(count) bölüm")
        case .department: String(localized: "\(count) ders")
        case .lesson: String(localized: "\(count) sınav")
        case .exam: ""
        }
    }
}

extension ExamKind {
    var symbolName: String {
        switch self {
        case .images: "photo.on.rectangle.angled"
        case .pdf: "doc.richtext.fill"
        }
    }

    /// Short format label shown as a badge.
    var badge: String {
        switch self {
        case .images: String(localized: "Görsel")
        case .pdf: "PDF"
        }
    }

    /// "4 sayfa" for images, "PDF" for documents.
    func contentText(fileCount: Int) -> String {
        switch self {
        case .images: String(localized: "\(fileCount) sayfa")
        case .pdf: String(localized: "PDF belge")
        }
    }
}
