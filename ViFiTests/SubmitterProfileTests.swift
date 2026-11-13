import Foundation
import Testing
@testable import ViFi

/// A `SubmitterProfileReading` with scripted replies per uid that counts every read.
final class StubSubmitterReader: SubmitterProfileReading, @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    var replies: [String: Result<SubmitterInfo?, any Error>] = [:]

    func reads(of uid: String) -> Int {
        lock.withLock { counts[uid] ?? 0 }
    }

    func submitter(uid: String) async throws -> SubmitterInfo? {
        lock.withLock { counts[uid, default: 0] += 1 }
        return try (replies[uid] ?? .success(nil)).get()
    }
}

@MainActor
@Suite("Submitter lookup")
struct SubmitterProfileTests {
    private let info = SubmitterInfo(
        fullName: "Ayşe Demir", university: "Boğaziçi Üniversitesi",
        faculty: "Mühendislik Fakültesi", department: "Bilgisayar Mühendisliği"
    )

    private func makeViewModel(_ reader: StubSubmitterReader) -> ModerationViewModel {
        ModerationViewModel(service: StubModerationService(pending: []), submitterReader: reader)
    }

    @Test("The same uid is read once, however many rows ask")
    func cachesPerUid() async {
        let reader = StubSubmitterReader()
        reader.replies["u1"] = .success(info)
        let viewModel = makeViewModel(reader)

        await viewModel.loadSubmitter(uid: "u1")
        await viewModel.loadSubmitter(uid: "u1")

        #expect(reader.reads(of: "u1") == 1)
        #expect(viewModel.submitters["u1"] == .loaded(info))
    }

    @Test("A missing profile is reported as missing, and not re-read")
    func missingProfile() async {
        let reader = StubSubmitterReader()
        let viewModel = makeViewModel(reader)

        await viewModel.loadSubmitter(uid: "gone")
        await viewModel.loadSubmitter(uid: "gone")

        #expect(viewModel.submitters["gone"] == .missing)
        #expect(reader.reads(of: "gone") == 1)
    }

    @Test("A read error is non-blocking and retried on the next ask")
    func errorIsRetried() async {
        let reader = StubSubmitterReader()
        reader.replies["u1"] = .failure(ProfileError.offline)
        let viewModel = makeViewModel(reader)

        await viewModel.loadSubmitter(uid: "u1")
        #expect(viewModel.submitters["u1"] == .failed)

        reader.replies["u1"] = .success(info)
        await viewModel.loadSubmitter(uid: "u1")

        #expect(viewModel.submitters["u1"] == .loaded(info))
        #expect(reader.reads(of: "u1") == 2)
    }

    @Test("Different uids are read separately")
    func separateUids() async {
        let reader = StubSubmitterReader()
        reader.replies["a"] = .success(info)
        let viewModel = makeViewModel(reader)

        await viewModel.loadSubmitter(uid: "a")
        await viewModel.loadSubmitter(uid: "b")

        #expect(viewModel.submitters["a"] == .loaded(info))
        #expect(viewModel.submitters["b"] == .missing)
    }

    @Test("The parser keeps name and affiliation and ignores the phone number and gender")
    func parserIgnoresPhone() {
        let value: [String: Any] = [
            "name": "Ayşe", "surname": "Demir", "university": "Boğaziçi Üniversitesi",
            "faculty": "Mühendislik Fakültesi", "department": "Bilgisayar Mühendisliği",
            "gender": "female", "phoneNumber": "+900000000000",
        ]

        let parsed = SubmitterInfoParser.info(from: value)

        #expect(parsed == info)
        #expect(!String(describing: parsed).contains("+90"))
    }

    @Test("The parser rejects a profile without a name, and tolerates missing affiliation")
    func parserEdges() {
        #expect(SubmitterInfoParser.info(from: nil) == nil)
        #expect(SubmitterInfoParser.info(from: ["surname": "Demir"]) == nil)
        let sparse = SubmitterInfoParser.info(from: ["name": "Ayşe", "surname": "Demir"])
        #expect(sparse == SubmitterInfo(fullName: "Ayşe Demir", university: "", faculty: "", department: ""))
        #expect(sparse.map(SubmitterSummary.affiliation)?.isEmpty == true)
        #expect(SubmitterSummary.affiliation(info) == "Boğaziçi Üniversitesi · Bilgisayar Mühendisliği")
    }
}
