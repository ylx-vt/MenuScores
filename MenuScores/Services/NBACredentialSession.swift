import Foundation

/// One process-local credential lease. The condition protects every field;
/// Keychain access runs outside it, so concurrent requests share one read.
/// Values never leave memory through this type. It does not change Keychain ACLs.
final class NBACredentialSession: @unchecked Sendable {
    enum Suspension: Hashable { case screen, session, sleep, keychain, mutation }
    enum Failure: Error, LocalizedError, Equatable {
        case suspended, changed
        var errorDescription: String? {
            switch self {
            case .suspended: "系统锁定或休眠后已释放钥匙串会话。请在安全配置中解锁本次会话；不会自动重复弹窗。"
            case .changed: "钥匙串会话已更新，本次未使用旧凭据。请重新发起操作。"
            }
        }
    }
    private let condition = NSCondition()
    private let load: @Sendable (Bool) throws -> String?
    private var cached: String?
    private var resolved = false
    private var failure: (any Error)?
    private var reading = false
    private var readingInteractive = false
    private var generation: UInt64 = 0
    private var suspended: Set<Suspension> = []

    init(load: @escaping @Sendable (Bool) throws -> String?) { self.load = load }

    func read(allowInteraction: Bool = false) throws -> String? {
        condition.lock()
        let ticket = generation
        var waitedForInteractive = false
        while true {
            guard generation == ticket else { condition.unlock(); throw Failure.changed }
            // Only the explicit user unlock action may initiate system UI.
            if !allowInteraction, !suspended.isEmpty { condition.unlock(); throw Failure.suspended }
            if resolved { let value = cached; condition.unlock(); return value }
            if let failure, !allowInteraction || waitedForInteractive { condition.unlock(); throw failure }
            if reading { waitedForInteractive = waitedForInteractive || readingInteractive; condition.wait(); continue }
            if allowInteraction { suspended.removeAll(); failure = nil }
            reading = true
            readingInteractive = allowInteraction
            condition.unlock()
            let result = Result { try load(allowInteraction) }
            condition.lock()
            reading = false
            defer { condition.broadcast(); condition.unlock() }
            guard generation == ticket else { throw Failure.changed }
            switch result {
            case .success(let value): cached = value; resolved = true; failure = nil; return value
            case .failure(let error): cached = nil; resolved = false; failure = error; throw error
            }
        }
    }
    /// Save/delete are explicit user operations. Replacing the lease also
    /// prevents a delayed old read from repopulating it afterwards.
    func replace(with value: String?) {
        condition.lock(); defer { condition.broadcast(); condition.unlock() }
        generation &+= 1; cached = value; resolved = true; failure = nil
    }
    func clear() {
        condition.lock(); defer { condition.broadcast(); condition.unlock() }
        invalidate()
    }
    func suspend(_ reason: Suspension) {
        condition.lock(); defer { condition.broadcast(); condition.unlock() }
        suspended.insert(reason); invalidate()
    }
    func resume(_ reason: Suspension) {
        condition.lock(); defer { condition.broadcast(); condition.unlock() }
        suspended.remove(reason)
    }
    private func invalidate() { generation &+= 1; cached = nil; resolved = false; failure = nil }
}
