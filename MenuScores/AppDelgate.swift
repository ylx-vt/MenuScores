//
//  AppDelgate.swift
//  MenuScores
//
//  Created by Daniyal Master on 2026-07-06.
//

import AppKit
import SwiftUI
import TourKit
import UserNotifications

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let tour = TourKitWindowController()

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !AppRuntime.isUnitTestHost else { return }
        // Normal credentials now come only from the user-approved private file.
        // Do not register legacy Keychain observers or probes for requests.
        guard !AppRuntime.isNotchPreview, !AppRuntime.isRestorationPreview, !AppRuntime.isTerraSummaryDemo, !AppRuntime.isCredentialSetup else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        guard NBANotificationRoute.destination(userInfo: notification.request.content.userInfo, identifier: notification.request.identifier) != nil else {
            completionHandler([]); return
        }
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let destination = NBANotificationRoute.destination(userInfo: response.notification.request.content.userInfo,
                                                                  identifier: response.notification.request.identifier) else {
            completionHandler(); return
        }
        Task { @MainActor in
            switch destination {
            case .game(let id): NBANotificationDetailWindow.shared.open(eventID: id)
            case .recap(let id, let key): await NBANotificationDetailWindow.shared.openArticle(eventID: id, cacheKey: key)
            }
            completionHandler()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NBAOpenAICredential.session.clear()
        NBANotchController.shared.stop()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !AppRuntime.isUnitTestHost else { return }
        if AppRuntime.isCredentialSetup { NBATerraCredentialSetup.shared.show(); return }
        if AppRuntime.isRecapNotificationSetup { SettingsWindowController.shared.showReminderSettings(); return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--menu-navigation-qa") {
            NBAMenuNavigationQA.run(); return
        }
        if ProcessInfo.processInfo.arguments.contains("--recap-today-rewrite") {
            NBARecapTodayRewrite.run(); return
        }
        if ProcessInfo.processInfo.arguments.contains("--recap-editorial-evaluate") {
            NBARecapEditorialEvaluation.run(); return
        }
        if ProcessInfo.processInfo.arguments.contains("--review-qa") || ProcessInfo.processInfo.arguments.contains("--review-live-test") {
            NBAReviewQA.run(); return
        }
        if ProcessInfo.processInfo.arguments.contains("--terra-autofill-now") {
            NBATerraBatchRunner.run()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--terra-native-qa") {
            NBATerraNativeQA.run()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--terra-authorized-smoke") {
            NBATerraAuthorizedSmoke.run()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--terra-key-setup") {
            NBATerraCredentialSetup.shared.exitsOnClose = true
            NBATerraCredentialSetup.shared.show()
            return
        }
        if AppRuntime.isTerraSummaryDemo {
            NBATerraSummaryDemo.shared.show()
            return
        }
        if AppRuntime.isRestorationPreview {
            NBARestorationPreview.shared.show()
            return
        }
        if AppRuntime.isNotchPreview {
            NSApp.setActivationPolicy(.accessory)
            NBANotchController.shared.preview()
            return
        }
        #endif
        if !AppRuntime.suppressesLiveWork {
            Task {
                let ready = (try? await Task.detached { try NBAOpenAIPrivateConfiguration.shared.prepareForUse() }.value) ?? false
                if !ready { NBATerraCredentialSetup.shared.show() }
            }
        }
        // Current product uses the shared NBA schedule and optional notch surface.
        NBANotchController.shared.configure()
        let hasShownTour = UserDefaults.standard.bool(forKey: "hasShownTour")

        if !hasShownTour {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)

            tour.present(
                pages: [
                    TourPage(imageName: "tour-welcome", title: "欢迎使用 MenuScores", description: "专注 NBA 的菜单栏比分工具"),
                    TourPage(imageName: "tour-detailed", title: "比分一眼可见", description: "用双方队标和比分，随时关注比赛。"),
                    TourPage(imageName: "tour-views", title: "查看球员技术统计", description: "点击菜单栏比分，查看得分、篮板、助攻与命中率。"),
                    TourPage(imageName: "tour-favorites", title: "关注喜爱的球队", description: "在设置中关注球队，比赛开始时自动固定比分。"),

                ],
                width: 660,
                continueButtonTitle: "继续",
                finishButtonTitle: "开始使用",
                onFinish: {
                    UserDefaults.standard.set(true, forKey: "hasShownTour")
                    NSApp.setActivationPolicy(.accessory)
                },
                onClose: {
                    UserDefaults.standard.set(true, forKey: "hasShownTour")
                    NSApp.setActivationPolicy(.accessory)
                }
            )
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
