import SwiftUI
import UIKit

/// Everything the "Bize Ulaş" (contact support) entry points share: the public support address, the
/// `mailto:` URL they open, and a reusable modifier that opens it — falling back to a copy-the-address
/// alert when the device has no mail client set up (common on the Simulator and on devices with no
/// Mail account).
enum ContactSupport {
    /// The app's public support address, shown to every user and prefilled into the `mailto:` link.
    ///
    /// Deliberately public: this is the "contact us" address, carrying the vendor name already in the
    /// bundle identifier (`com.BuyukerYazilim.…`), not a private contact — safe to live in the repo.
    static let email = "buyukeryazilim@gmail.com"

    /// The subject prefilled for the user; they can edit it before sending.
    static let subject = "ViFi — Bize Ulaş"

    /// Builds the `mailto:` URL, optionally prefilling `context` (for example which exam the user is
    /// writing about) above a short diagnostic footer. Returns `nil` only if the address cannot be
    /// percent-encoded, which never happens for a literal address.
    static func mailtoURL(context: String? = nil, bundle: Bundle = .main) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body(context: context, bundle: bundle)),
        ]
        return components.url
    }

    /// The prefilled e-mail body: the context line (if any), an empty area for the user to type, then a
    /// separator and the app/iOS version so support can reproduce version-specific issues. It carries
    /// no personal data — no name, phone number or user id.
    static func body(context: String? = nil, bundle: Bundle = .main) -> String {
        var lines: [String] = []
        if let context, !context.isEmpty {
            lines.append(context)
            lines.append("")
        }
        lines.append("")
        lines.append("—")
        lines.append("ViFi \(bundle.shortVersionString) (\(bundle.buildVersionString)) · iOS \(UIDevice.current.systemVersion)")
        return lines.joined(separator: "\n")
    }
}

extension Bundle {
    /// `CFBundleVersion` ("6"), or "0" when it is somehow absent.
    var buildVersionString: String {
        object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}

// MARK: - Reusable entry point

/// One contact request. A fresh instance (new `id`) per tap, so tapping the same screen's button
/// twice still re-fires the opening.
struct ContactRequest: Identifiable {
    let id = UUID()
    /// A one-line reference prefilled above the message, e.g. the exam the user is writing about.
    let context: String?

    init(context: String? = nil) {
        self.context = context
    }
}

extension View {
    /// Opens a support `mailto:` e-mail whenever `trigger` is set to a new request, and shows a
    /// copy-the-address alert when no mail client can handle it. Attach once to a screen's content;
    /// drive it from a button with `trigger = ContactRequest(context:)`.
    func contactSupport(trigger: Binding<ContactRequest?>) -> some View {
        modifier(ContactSupportModifier(trigger: trigger))
    }
}

private struct ContactSupportModifier: ViewModifier {
    @Binding var trigger: ContactRequest?
    @Environment(\.openURL) private var openURL
    @State private var isShowingFallback = false

    func body(content: Content) -> some View {
        content
            .onChange(of: trigger?.id) { _, newID in
                guard newID != nil, let request = trigger else { return }
                send(request)
            }
            .alert("Mail uygulaması bulunamadı", isPresented: $isShowingFallback) {
                Button("Adresi Kopyala") {
                    UIPasteboard.general.string = ContactSupport.email
                }
                Button("Tamam", role: .cancel) {}
            } message: {
                Text("\(ContactSupport.email) adresine e-posta gönderebilirsiniz.")
            }
    }

    /// Opens Mail with the prefilled message, or offers the address to copy when nothing can open it.
    private func send(_ request: ContactRequest) {
        guard let url = ContactSupport.mailtoURL(context: request.context),
              UIApplication.shared.canOpenURL(url) else {
            isShowingFallback = true
            return
        }
        openURL(url)
    }
}
