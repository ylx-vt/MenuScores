import AppKit
import Security

/// Notification-only observers: never enumerate/read items or change access.
@MainActor enum NBACredentialLifecycle {
    private static var tokens: [NSObjectProtocol] = []
    private static var started = false
    static func start() {
        guard !started else { return }; started = true
        let lease = NBAOpenAICredential.session, workspace = NSWorkspace.shared.notificationCenter
        let suspensions: [(Notification.Name, NBACredentialSession.Suspension)] = [
            (NSWorkspace.willSleepNotification, .sleep), (NSWorkspace.sessionDidResignActiveNotification, .session)]
        for (name, reason) in suspensions {
            tokens.append(workspace.addObserver(forName: name, object: nil, queue: nil) { _ in lease.suspend(reason) })
        }
        tokens.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in lease.resume(.sleep) })
        tokens.append(workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: nil) { _ in lease.resume(.session) })
        let distributed = DistributedNotificationCenter.default()
        tokens.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: nil) { _ in lease.suspend(.screen) })
        tokens.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: nil) { _ in lease.resume(.screen) })
        // Existing login-Keychain lock/unlock notifications only; no item data
        // or ACLs are inspected. Register on the main run loop as Apple requires.
        SecKeychainAddCallback({ event, _, _ in
            if event == .lockEvent { NBAOpenAICredential.session.suspend(.keychain) }
            if event == .unlockEvent { NBAOpenAICredential.session.resume(.keychain) }
            return errSecSuccess
        }, [.lockEventMask, .unlockEventMask], nil)
    }
}
