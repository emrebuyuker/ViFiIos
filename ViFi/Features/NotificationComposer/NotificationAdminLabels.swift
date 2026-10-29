import SwiftUI

// Turkish labels for the admin notification screens. Named `admin…` so they cannot collide with the inbox's own
// presentation helpers.

extension NotificationKind {
    /// "Duyuru" / "Kampanya" / "Sistem".
    var adminLabel: String {
        switch self {
        case .general: String(localized: "Duyuru")
        case .promo: String(localized: "Kampanya")
        case .system: String(localized: "Sistem")
        }
    }

    var adminSymbol: String {
        switch self {
        case .general: "megaphone.fill"
        case .promo: "tag.fill"
        case .system: "bell.badge.fill"
        }
    }
}

extension NotificationStatus {
    var adminLabel: String {
        switch self {
        case .scheduled: String(localized: "Zamanlandı")
        case .sending: String(localized: "Gönderiliyor")
        case .sent: String(localized: "Gönderildi")
        case .failed: String(localized: "Başarısız")
        case .canceled: String(localized: "İptal edildi")
        }
    }

    var adminTint: Color {
        switch self {
        case .scheduled: .orange
        case .sending: .blue
        case .sent: .green
        case .failed: .red
        case .canceled: .gray
        }
    }
}
