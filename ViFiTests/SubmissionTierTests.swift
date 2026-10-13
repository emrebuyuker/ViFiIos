import Testing
@testable import ViFi

@Suite("SubmissionTier")
struct SubmissionTierTests {
    @Test("The first missing archive level decides the tier")
    func classifyByFirstMissingLevel() {
        #expect(SubmissionTier.classify(
            universityExists: false, facultyExists: false, departmentExists: false,
            courseExists: false, examExists: false) == .newUniversity)
        #expect(SubmissionTier.classify(
            universityExists: true, facultyExists: false, departmentExists: false,
            courseExists: false, examExists: false) == .newFaculty)
        #expect(SubmissionTier.classify(
            universityExists: true, facultyExists: true, departmentExists: false,
            courseExists: false, examExists: false) == .newDepartment)
        #expect(SubmissionTier.classify(
            universityExists: true, facultyExists: true, departmentExists: true,
            courseExists: false, examExists: false) == .newCourse)
        #expect(SubmissionTier.classify(
            universityExists: true, facultyExists: true, departmentExists: true,
            courseExists: true, examExists: false) == .newExam)
    }

    @Test("Everything already present is a duplicate")
    func duplicateWhenAllPresent() {
        #expect(SubmissionTier.classify(
            universityExists: true, facultyExists: true, departmentExists: true,
            courseExists: true, examExists: true) == .duplicate)
    }

    @Test("A missing ancestor outranks a present descendant")
    func missingAncestorWins() {
        // A new university, even if (hypothetically) a same-named exam existed elsewhere.
        #expect(SubmissionTier.classify(
            universityExists: false, facultyExists: true, departmentExists: true,
            courseExists: true, examExists: true) == .newUniversity)
    }

    @Test("Every tier has a non-empty label")
    func everyTierHasLabel() {
        for tier in SubmissionTier.allCases {
            #expect(!tier.label.isEmpty)
        }
    }
}

@Suite("RewardsConfig.coins(for:)")
struct RewardsConfigCoinsTests {
    @Test("A configured tier amount is used")
    func usesTierAmount() {
        let config = RewardsConfig(examUploadCoins: 10, tiers: [.newUniversity: 500])
        #expect(config.coins(for: .newUniversity) == 500)
    }

    @Test("A tier with no amount falls back to the flat value")
    func fallsBackToFlatValue() {
        let config = RewardsConfig(examUploadCoins: 10, tiers: [.newUniversity: 500])
        #expect(config.coins(for: .duplicate) == 10)
    }

    @Test("With neither a tier amount nor a flat value, nothing is promised")
    func nothingPromised() {
        let config = RewardsConfig(examUploadCoins: nil, tiers: [:])
        #expect(config.coins(for: .newExam) == nil)
    }
}
