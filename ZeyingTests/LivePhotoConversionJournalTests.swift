import Foundation
import Testing
@testable import Zeying

@MainActor
struct LivePhotoConversionJournalTests {
    @Test("旧转换记录中的已有副本必须重新核对")
    func legacyCopyDoesNotImplyVerification() throws {
        let record = sample(verification: .verified)
        let data = try JSONEncoder().encode(record)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "verification")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(LivePhotoConversion.self, from: legacyData)

        #expect(decoded.stillIdentifier == "still-copy")
        #expect(decoded.phase == .awaitingOriginalDeletion)
        #expect(decoded.verification == .pending)
    }

    @Test("重开后保留失败或成功的核对结果", arguments: [
        LivePhotoConversion.Verification.failed,
        LivePhotoConversion.Verification.verified
    ])
    func verificationSurvivesReopen(_ verification: LivePhotoConversion.Verification) throws {
        let suite = "ConversionJournalTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(["source": sample(verification: verification)]),
            forKey: "com.mars.zeying.liveConversionJournal.v1")

        let reopened = LivePhotoConversionManager(defaults: defaults)
        #expect(reopened.journalError == nil)
        #expect(reopened.conversion(for: "source")?.verification == verification)
        #expect(reopened.conversion(for: "source")?.stillIdentifier == "still-copy")
    }

    private func sample(verification: LivePhotoConversion.Verification) -> LivePhotoConversion {
        LivePhotoConversion(
            sourceIdentifier: "source", token: UUID(),
            startedAt: Date(timeIntervalSince1970: 100),
            creationDate: Date(timeIntervalSince1970: 50),
            sourceModificationDate: nil, albumIdentifiers: ["family"],
            stillIdentifier: "still-copy", phase: .awaitingOriginalDeletion,
            verification: verification
        )
    }
}
