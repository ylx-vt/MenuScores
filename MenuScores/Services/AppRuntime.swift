import Foundation

/// Hosted unit tests exercise stores with their own fixtures and temporary paths.
/// They must not also launch production polling, onboarding or notification work.
enum AppRuntime {
    static var isNotchPreview: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--notch-preview")
        #else
        return false
        #endif
    }
    static var isRestorationPreview: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--restoration-preview")
        #else
        return false
        #endif
    }
    static var isTerraSummaryDemo: Bool {
        #if DEBUG
        return ["--menu-navigation-qa", "--review-qa", "--review-live-test", "--recap-editorial-evaluate", "--recap-today-rewrite", "--terra-summary-demo", "--terra-key-setup", "--terra-authorized-smoke", "--terra-native-qa", "--terra-autofill-now"].contains { ProcessInfo.processInfo.arguments.contains($0) }
        #else
        return false
        #endif
    }
    static var isCredentialSetup: Bool { ProcessInfo.processInfo.arguments.contains("--configure-terra") }
    static var isRecapNotificationSetup: Bool { ProcessInfo.processInfo.arguments.contains("--configure-recap-notifications") }
    static var suppressesLiveWork: Bool { isUnitTestHost || isNotchPreview || isRestorationPreview || isTerraSummaryDemo || isCredentialSetup || isRecapNotificationSetup }
    static var isUnitTestHost: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil ||
            environment["XCTestBundlePath"] != nil || NSClassFromString("XCTestCase") != nil
    }
}
