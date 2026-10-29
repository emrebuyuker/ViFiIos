import Foundation
import Testing
@testable import ViFi

@Suite("GoogleMapsConfiguration")
struct GoogleMapsConfigurationTests {
    @Test("A key in the Info.plist is usable, trimmed")
    func usableKey() {
        let configuration = GoogleMapsConfiguration(infoDictionary: ["GMSApiKey": "  test-key-123 \n"])

        #expect(configuration.apiKey == "test-key-123")
        #expect(configuration.isAvailable)
    }

    @Test("A missing, empty or blank key means unavailable")
    func missingKey() {
        #expect(!GoogleMapsConfiguration(infoDictionary: nil).isAvailable)
        #expect(!GoogleMapsConfiguration(infoDictionary: [:]).isAvailable)
        #expect(!GoogleMapsConfiguration(infoDictionary: ["GMSApiKey": ""]).isAvailable)
        #expect(!GoogleMapsConfiguration(infoDictionary: ["GMSApiKey": "   "]).isAvailable)
        #expect(GoogleMapsConfiguration(infoDictionary: ["GMSApiKey": ""]).apiKey == nil)
    }

    @Test("A build setting that was never expanded means unavailable")
    func unexpandedKey() {
        #expect(!GoogleMapsConfiguration(infoDictionary: ["GMSApiKey": "$(GOOGLE_MAPS_API_KEY)"]).isAvailable)
        #expect(!GoogleMapsConfiguration(infoDictionary: ["GMSApiKey": "${GOOGLE_MAPS_API_KEY}"]).isAvailable)
    }

    @Test("A value that is not a string means unavailable")
    func wrongType() {
        #expect(!GoogleMapsConfiguration(infoDictionary: ["GMSApiKey": 42]).isAvailable)
    }

    @Test("Without a key the SDKs are not started")
    func notStartedWithoutKey() {
        #expect(!GoogleMapsSDK.startIfPossible(GoogleMapsConfiguration(infoDictionary: [:])))
        #expect(!GoogleMapsSDK.startIfPossible(GoogleMapsConfiguration(infoDictionary: ["GMSApiKey": "$(GOOGLE_MAPS_API_KEY)"])))
    }

    @Test("The key is read from GMSApiKey")
    func keyName() {
        #expect(GoogleMapsConfiguration.infoDictionaryKey == "GMSApiKey")
        #expect(!GoogleMapsConfiguration(infoDictionary: ["GoogleMapsKey": "test-key-123"]).isAvailable)
    }
}
