import Foundation
import Testing
@testable import ViFi

@Suite("FirebaseRewardsConfigReader")
struct FirebaseRewardsConfigReaderTests {
    @Test("A positive coin count is parsed")
    func parsesPositiveCoins() {
        #expect(FirebaseRewardsConfigReader.parse(["examUploadCoins": 25]) == RewardsConfig(examUploadCoins: 25))
    }

    @Test("A missing coin field yields a config with no amount")
    func missingCoinField() {
        #expect(FirebaseRewardsConfigReader.parse([String: Any]()) == RewardsConfig(examUploadCoins: nil))
    }

    @Test("A non-positive or malformed coin value is dropped", arguments: [0, -5])
    func dropsNonPositive(value: Int) {
        #expect(FirebaseRewardsConfigReader.parse(["examUploadCoins": value]) == RewardsConfig(examUploadCoins: nil))
    }

    @Test("A non-object value yields nil")
    func nonObjectYieldsNil() {
        #expect(FirebaseRewardsConfigReader.parse(nil) == nil)
        #expect(FirebaseRewardsConfigReader.parse("not-an-object") == nil)
    }

    @Test("A non-numeric coin value is dropped")
    func nonNumericCoinValue() {
        #expect(FirebaseRewardsConfigReader.parse(["examUploadCoins": "ten"]) == RewardsConfig(examUploadCoins: nil))
    }

    @Test("Per-tier amounts are parsed by their raw keys")
    func parsesTiers() {
        let config = FirebaseRewardsConfigReader.parse([
            "examUploadCoins": 10,
            "tiers": [
                "newUniversity": 500,
                "newFaculty": 300,
                "duplicate": 5,
            ],
        ])
        #expect(config == RewardsConfig(examUploadCoins: 10, tiers: [
            .newUniversity: 500,
            .newFaculty: 300,
            .duplicate: 5,
        ]))
    }

    @Test("Unknown tier keys and non-positive tier amounts are dropped")
    func dropsInvalidTiers() {
        let config = FirebaseRewardsConfigReader.parse([
            "tiers": [
                "newUniversity": 500,
                "bogusTier": 999,
                "newExam": 0,
                "duplicate": -3,
            ],
        ])
        #expect(config == RewardsConfig(examUploadCoins: nil, tiers: [.newUniversity: 500]))
    }

    @Test("A malformed tiers value leaves the tiers empty")
    func malformedTiers() {
        #expect(FirebaseRewardsConfigReader.parse(["tiers": "nope"]) == RewardsConfig(examUploadCoins: nil))
    }
}
