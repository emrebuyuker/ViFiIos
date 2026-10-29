import UIKit

/// Whether the app shows a modal (sheet, cover or alert) over its main screen, from any view. SwiftUI offers no
/// app-wide view of that, so it is read from the key window's presentation chain.
enum ModalPresentation {
    static var isShowing: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains { $0.isKeyWindow && $0.rootViewController?.presentedViewController != nil }
    }
}
