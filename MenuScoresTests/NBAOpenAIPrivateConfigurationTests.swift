import Foundation
import Security
import Testing
@testable import MenuScores

struct NBAOpenAIPrivateConfigurationTests {
    private let fixture = "fixture-only-not-a-real-key"
    private func folder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("MenuScores-private-test-" + UUID().uuidString) }

    @Test func continuousQuestionsAndNewInstanceReadOnlyPrivateFile() throws {
        let root = folder(), probe = CredentialProbe()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NBAOpenAIPrivateConfiguration(directory:root) { mode in probe.record(mode); return "fixture-only-not-a-real-key" }
        try store.save(fixture)
        for _ in 0..<2 {
            let client = NBATerraClient(authorized:true,credential:{ try store.readForAuthorizedRequest() })
            for _ in 0..<4 { #expect(try client.credential() == fixture) }
        }
        let restarted = NBAOpenAIPrivateConfiguration(directory:root) { mode in probe.record(mode); return nil }
        #expect(try restarted.prepareForUse())
        #expect(try restarted.readForAuthorizedRequest() == fixture)
        #expect(probe.count == 0)
        #expect(store.diagnosticSnapshot().legacyMigrationReads == 0)
        #expect(restarted.diagnosticSnapshot().legacyMigrationReads == 0)
        let file = try FileManager.default.attributesOfItem(atPath:store.fileURL.path)
        let dir = try FileManager.default.attributesOfItem(atPath:root.path)
        #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((dir[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let diagnostics = try String(contentsOf:store.diagnosticsURL,encoding:.utf8)
        #expect(!diagnostics.contains(fixture) && !diagnostics.contains("apiKey"))
    }
    @Test func migrationIsBoundedAndNeverDeletesLegacyItem() throws {
        let root = folder(), probe = CredentialProbe()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NBAOpenAIPrivateConfiguration(directory:root) { mode in probe.record(mode); return "fixture-only-not-a-real-key" }
        #expect(try store.prepareForUse())
        #expect(try store.prepareForUse())
        #expect(try store.migrateLegacy(allowInteraction:true))
        #expect(probe.count == 1 && probe.interactions == 0)
        #expect(store.diagnosticSnapshot().migrationsCompleted == 1)
        try store.removeLocalConfiguration()
        #expect(throws:NBAOpenAIPrivateConfiguration.Failure.self) { try store.readForAuthorizedRequest() }
        #expect(try store.prepareForUse() == false)
        #expect(probe.count == 1)
        let restarted = NBAOpenAIPrivateConfiguration(directory:root) { mode in probe.record(mode); return "fixture-only-not-a-real-key" }
        #expect(try restarted.prepareForUse() == false)
        #expect(probe.count == 1)
    }
    @Test func canceledMigrationRequiresExplicitRetryNotEveryQuestion() throws {
        let root = folder(), probe = CredentialProbe()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NBAOpenAIPrivateConfiguration(directory:root) { mode in probe.record(mode); throw NBAOpenAICredential.Failure(status:errSecUserCanceled) }
        #expect(throws:NBAOpenAICredential.Failure.self) { try store.migrateLegacy(allowInteraction:true) }
        for _ in 0..<5 { #expect(throws:NBAOpenAIPrivateConfiguration.Failure.self) { try store.readForAuthorizedRequest() } }
        #expect(try store.prepareForUse() == false)
        #expect(probe.count == 1)
        #expect(store.diagnosticSnapshot().lastMigrationStatus == errSecUserCanceled)
        #expect(!store.isConfigured)
    }
    @Test func malformedAndMissingFilesNeverFallBackToKeychain() throws {
        let root = folder(), probe = CredentialProbe()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NBAOpenAIPrivateConfiguration(directory:root) { mode in probe.record(mode); return nil }
        #expect(throws:NBAOpenAIPrivateConfiguration.Failure.self) { try store.readForAuthorizedRequest() }
        try store.save(fixture)
        try Data("{not json}".utf8).write(to:store.fileURL)
        #expect(throws:NBAOpenAIPrivateConfiguration.Failure.self) { try store.readForAuthorizedRequest() }
        #expect(throws:NBAOpenAIPrivateConfiguration.Failure.self) { try store.prepareForUse() }
        #expect(probe.count == 0)
        try store.save(fixture)
        #expect(try store.readForAuthorizedRequest() == fixture)
    }
    @Test func unsafePermissionsAndSymbolicLinksAreRejected() throws {
        let root = folder(), probe = CredentialProbe()
        defer { try? FileManager.default.removeItem(at:root) }
        let store = NBAOpenAIPrivateConfiguration(directory:root) { mode in probe.record(mode); return nil }
        try store.save(fixture)
        try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:store.fileURL.path)
        #expect(throws:NBAOpenAIPrivateConfiguration.Failure.self) { try store.readForAuthorizedRequest() }
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:store.fileURL.path)
        let other = root.appendingPathComponent("other.json")
        try FileManager.default.moveItem(at:store.fileURL,to:other)
        try FileManager.default.createSymbolicLink(at:store.fileURL,withDestinationURL:other)
        #expect(throws:NBAOpenAIPrivateConfiguration.Failure.self) { try store.readForAuthorizedRequest() }
        #expect(throws:NBAOpenAIPrivateConfiguration.Failure.self) { try store.save(fixture) }
        #expect(probe.count == 0)
    }
    @Test func concurrentReadsAfterMigrationDoNotReenterLegacyProvider() async throws {
        let root = folder(), probe = CredentialProbe()
        defer { try? FileManager.default.removeItem(at:root) }
        let store = NBAOpenAIPrivateConfiguration(directory:root) { mode in probe.record(mode); return "fixture-only-not-a-real-key" }
        #expect(try store.migrateLegacy(allowInteraction:true))
        let reads = (0..<12).map { _ in Task.detached { try store.readForAuthorizedRequest() } }
        for task in reads { #expect(try await task.value == fixture) }
        #expect(probe.count == 1)
    }
}
