import Foundation
import Testing
@testable import ViFi

@MainActor
@Suite("ContactSupport")
struct ContactSupportTests {
    /// Decodes the `mailto:` URL back into its address and query items for inspection.
    private func parse(_ url: URL) throws -> (address: String, items: [String: String]) {
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        return (components.path, items)
    }

    @Test("The mailto URL targets the support address with a prefilled subject")
    func addressAndSubject() throws {
        let url = try #require(ContactSupport.mailtoURL())
        #expect(url.scheme == "mailto")

        let parsed = try parse(url)
        #expect(parsed.address == ContactSupport.email)
        #expect(parsed.items["subject"] == ContactSupport.subject)
    }

    @Test("The body carries the app and iOS version footer but no context by default")
    func bodyFooterWithoutContext() throws {
        let url = try #require(ContactSupport.mailtoURL())
        let body = try parse(url).items["body"]
        let value = try #require(body)

        #expect(value.contains("ViFi "))
        #expect(value.contains("· iOS "))
        #expect(!value.contains("Sınav:"))
    }

    @Test("A context line is prefilled above the footer")
    func bodyIncludesContext() throws {
        let context = "Sınav: BOZOK ÜNİVERSİTESİ › MÜHENDİSLİK MATEMATİĞİ › 2019 FİNAL"
        let url = try #require(ContactSupport.mailtoURL(context: context))
        let value = try #require(try parse(url).items["body"])

        #expect(value.hasPrefix(context))
        #expect(value.contains("ViFi "))
    }

    @Test("An empty context is treated as no context")
    func emptyContextIsIgnored() throws {
        let body = ContactSupport.body(context: "")
        #expect(!body.contains("Sınav:"))
        #expect(body.contains("ViFi "))
    }
}
