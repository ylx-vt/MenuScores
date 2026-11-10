import Foundation
import Security
import Testing
@testable import MenuScores

final class CredentialProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var modes: [Bool] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return modes.count }
    var interactions: Int { lock.lock(); defer { lock.unlock() }; return modes.filter { $0 }.count }
    func record(_ mode: Bool) { lock.lock(); modes.append(mode); lock.unlock() }
}

struct NBACredentialSessionTests {
    @Test func bothModelPassesAndLaterQuestionsReuseOneSuccessfulRead() throws {
        let probe = CredentialProbe(), lease = NBACredentialSession { mode in probe.record(mode); return "fixture-credential" }
        // Two passes × input count + generation, across three questions and
        // independently created clients, all share the same process lease.
        for _ in 0..<3 {
            let client = NBATerraClient(authorized: true, credential: { try lease.read() })
            for _ in 0..<4 { #expect(try client.credential() == "fixture-credential") }
        }
        #expect(probe.count == 1); #expect(probe.interactions == 0)
        #expect(try lease.read(allowInteraction: true) == "fixture-credential")
        #expect(probe.count == 1)
    }
    @Test func permissionFailureIsStickyUntilAnExplicitUserUnlock() throws {
        let probe = CredentialProbe(), lease = NBACredentialSession { interactive in
            probe.record(interactive)
            if !interactive { throw NBAOpenAICredential.Failure(status: errSecInteractionNotAllowed) }
            return "fixture-credential"
        }
        for _ in 0..<6 { #expect(throws: NBAOpenAICredential.Failure.self) { try lease.read() } }
        #expect(probe.count == 1)
        #expect(try lease.read(allowInteraction: true) == "fixture-credential")
        #expect(try lease.read() == "fixture-credential")
        #expect(probe.count == 2); #expect(probe.interactions == 1)
    }
    @Test func concurrentReadsShareOneSlowKeychainResult() async throws {
        let probe = CredentialProbe(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let lease = NBACredentialSession { mode in probe.record(mode); entered.signal(); release.wait(); return "fixture-credential" }
        let first = Task.detached { try lease.read(allowInteraction: true) }
        entered.wait()
        let others = (0..<12).map { _ in Task.detached { try lease.read() } }
        release.signal()
        #expect(try await first.value == "fixture-credential")
        for other in others { #expect(try await other.value == "fixture-credential") }
        #expect(probe.count == 1); #expect(probe.interactions == 1)
    }
    @Test func failedConcurrentUnlockDoesNotCascadeIntoMultipleSystemPrompts() async throws {
        let probe = CredentialProbe(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), waiting = DispatchSemaphore(value: 0)
        let lease = NBACredentialSession { mode in probe.record(mode); entered.signal(); release.wait(); throw NBAOpenAICredential.Failure(status: errSecUserCanceled) }
        let first = Task.detached { try lease.read(allowInteraction: true) }; entered.wait()
        let second = Task.detached { waiting.signal(); return try lease.read() }; waiting.wait()
        release.signal()
        do { _ = try await first.value; Issue.record("Expected user cancellation") } catch { #expect(error is NBAOpenAICredential.Failure) }
        do { _ = try await second.value; Issue.record("Expected shared failure") } catch { #expect(error is NBAOpenAICredential.Failure) }
        #expect(probe.count == 1)
    }
    @Test func lockSleepAndKeychainReasonsMustEachResumeBeforeReusing() throws {
        let probe = CredentialProbe(), lease = NBACredentialSession { mode in probe.record(mode); return "fixture-credential" }
        _ = try lease.read(); lease.suspend(.screen); lease.suspend(.sleep); lease.suspend(.keychain)
        for _ in 0..<4 { #expect(throws: NBACredentialSession.Failure.suspended) { try lease.read() } }
        lease.resume(.sleep); lease.resume(.screen)
        #expect(throws: NBACredentialSession.Failure.suspended) { try lease.read() }
        lease.resume(.keychain)
        #expect(try lease.read() == "fixture-credential"); #expect(probe.count == 2)
        lease.suspend(.session)
        #expect(throws: NBACredentialSession.Failure.suspended) { try lease.read() }
        lease.resume(.session); _ = try lease.read(); #expect(probe.count == 3)
    }
    @Test func delayedOldReadsCannotRestoreAKeyAfterClearLockOrReplacement() async throws {
        for action in ["clear", "lock", "replace"] {
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let lease = NBACredentialSession { _ in entered.signal(); release.wait(); return "old-fixture" }
            let task = Task.detached { try lease.read() }; entered.wait()
            if action == "clear" { lease.clear() }
            else if action == "lock" { lease.suspend(.screen) }
            else { lease.replace(with: "new-fixture") }
            release.signal()
            do { _ = try await task.value; Issue.record("Old read was not discarded") } catch { #expect(error as? NBACredentialSession.Failure == .changed) }
            if action == "replace" { #expect(try lease.read() == "new-fixture") }
            if action == "lock" { #expect(throws: NBACredentialSession.Failure.suspended) { try lease.read() } }
        }
    }
    @Test func saveDeleteMissingAndRestartHaveNoHiddenReadOrPersistentLease() throws {
        let probe = CredentialProbe(), lease = NBACredentialSession { mode in probe.record(mode); return nil }
        #expect(try lease.read() == nil); #expect(try lease.read() == nil); #expect(probe.count == 1)
        lease.replace(with: "new-fixture"); #expect(try lease.read() == "new-fixture"); #expect(probe.count == 1)
        lease.replace(with: nil); #expect(try lease.read() == nil); #expect(probe.count == 1)
        let restart = NBACredentialSession { mode in probe.record(mode); return nil }
        #expect(try restart.read() == nil); #expect(probe.count == 2)
    }
    @Test func explicitUserUnlockCanRecoverAfterMissedWakeNotification() throws {
        let probe = CredentialProbe(), lease = NBACredentialSession { mode in probe.record(mode); return "fixture-credential" }
        lease.suspend(.sleep)
        #expect(throws: NBACredentialSession.Failure.suspended) { try lease.read() }
        #expect(try lease.read(allowInteraction: true) == "fixture-credential")
        #expect(try lease.read() == "fixture-credential"); #expect(probe.count == 1)
    }
    @Test func explicitUnlockCanEscalateAnOverlappingSilentReadFailure() async throws {
        let probe = CredentialProbe(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let lease = NBACredentialSession { mode in
            probe.record(mode)
            if mode { return "fixture-credential" }
            entered.signal(); release.wait(); throw NBAOpenAICredential.Failure(status: errSecInteractionNotAllowed)
        }
        let background = Task.detached { try lease.read() }; entered.wait()
        let user = Task.detached { try lease.read(allowInteraction: true) }
        release.signal()
        do { _ = try await background.value; Issue.record("Expected silent failure") } catch { #expect(error is NBAOpenAICredential.Failure) }
        #expect(try await user.value == "fixture-credential")
        #expect(probe.count == 2); #expect(probe.interactions == 1)
        #expect(try lease.read() == "fixture-credential")
    }
}
