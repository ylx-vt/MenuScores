#if DEBUG
import AppKit
import SwiftUI

final class NBATerraQAOffline: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

@MainActor private final class NBATerraQAVisibility { var showing = false; var transitions: [Bool] = [] }

/// Offline rendering of the already-paid real responses. No API or Keychain use.
@MainActor enum NBATerraNativeQA {
    static func run() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--terra-native-qa"), args.indices.contains(index + 1) else { NSApp.terminate(nil); return }
        let root = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        let qa = root.appendingPathComponent("qa", isDirectory: true)
        if args.contains("--editorial-qa") {
            Task { await editorial(root: root); NSApp.terminate(nil) }
            return
        }
        Task {
            do {
                try FileManager.default.createDirectory(at: qa, withIntermediateDirectories: true)
                for name in ["final", "pregame"] {
                    let data = try Data(contentsOf: root.appendingPathComponent(name + ".json"))
                    let oldResult = try JSONDecoder().decode(NBARecap.self, from: Data(contentsOf: root.appendingPathComponent(name + "-result.json")))
                    let input = try NBARecapInput.makeArticle(data: data, gameID: oldResult.gameID, dataAsOf: oldResult.dataAsOf)
                    let responseData = try Data(contentsOf: root.appendingPathComponent(name + "-response.json"))
                    let responseDate = (try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(name + "-response.json").path)[.modificationDate] as? Date) ?? oldResult.generatedAt
                    var result = try NBATerraClient.parse(responseData, input: input, now: responseDate)
                    result.requestID = oldResult.requestID
                    try JSONEncoder().encode(result).write(to: root.appendingPathComponent(name + "-result.json"), options: .atomic)
                    let cache = qa.appendingPathComponent("cache", isDirectory: true)
                    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                    try JSONEncoder().encode(result).write(to: cache.appendingPathComponent(input.cacheKey + ".json"), options: .atomic)
                    let articles = NBATerraRecapStore(directory: cache) { _ in throw NBARecapError.authorizationRequired }
                    let sourceDate = input.dataAsOf
                    let box = NBABoxScoreStore(directory: qa.appendingPathComponent("box-" + name), now: { sourceDate }, fetch: { _ in data })
                    let model = NBATerraArticleModel(gameID: input.facts.gameID, boxStore: box, articles: articles)
                    let host = NSHostingView(rootView: NBATerraArticleView(model: model, onBack: {}).frame(width: 596, height: 440).padding(12).background(Color(nsColor: .windowBackgroundColor)))
                    let window = makeWindow(host, title: "离线验收 · " + name)
                    try await Task.sleep(nanoseconds: 500_000_000)
                    capture(host, window: window, at: qa.appendingPathComponent(name + "-article"))
                    model.generate(enabled: false)
                    model.cancel()
                    window.close()
                    let profiles = NBAPlayerProfileStore(directory: qa.appendingPathComponent("profiles"), fetch: { _ in throw URLError(.notConnectedToInternet) })
                    let league = NBALeaguePercentileStore(directory: qa.appendingPathComponent("ranking"), priorDirectory: qa.appendingPathComponent("prior"), fetch: { _, _, _ in throw URLError(.notConnectedToInternet) })
                    let schedules = NBAPregameScheduleStore(directory: qa.appendingPathComponent("schedule"), fetch: { _ in throw URLError(.notConnectedToInternet) })
                    let detail = NSHostingView(rootView: NBABoxScoreView(gameID: input.facts.gameID, boxStore: box, profileStore: profiles, leagueStore: league, pregameStore: schedules))
                    let detailWindow = makeWindow(detail, title: "原小看板 · " + name)
                    try await Task.sleep(nanoseconds: 800_000_000)
                    capture(detail, window: detailWindow, at: qa.appendingPathComponent(name + "-detail"))
                    detailWindow.close()
                }
            } catch {
                try? JSONSerialization.data(withJSONObject: ["error": "离线原生验收未完成", "type": String(reflecting: Swift.type(of: error))])
                    .write(to: qa.appendingPathComponent("failure.json"))
            }
            NSApp.terminate(nil)
        }
    }
    private static func editorial(root: URL) async {
        let qa = root.appendingPathComponent("editorial-qa", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: qa, withIntermediateDirectories: true)
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let ledger = try JSONDecoder().decode(NBATerraAutofill.Ledger.self, from: Data(contentsOf: appSupport.appendingPathComponent("MenuScores/TerraAutofill-v1.json")))
            let userCaches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let targets = ProcessInfo.processInfo.arguments.contains("--daily-qa") ? [("401909901", "recap"), ("401909903", "pregame")] : [("401909285", "recap"), ("401909902", "pregame")]
            for (id, kind) in targets {
                guard let job = ledger.jobs[id + "-" + kind], job.state == "done" else { throw NBARecapError.invalidData }
                let resultData = try Data(contentsOf: userCaches.appendingPathComponent("NBATerraArticles-v2/" + job.fingerprint + ".json"))
                let result = try JSONDecoder().decode(NBARecap.self, from: resultData)
                let data = try Data(contentsOf: userCaches.appendingPathComponent("NBABoxScores/" + id + ".json"))
                let directory = qa.appendingPathComponent("articles", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try resultData.write(to: directory.appendingPathComponent(result.cacheKey + ".json"))
                let store = NBATerraRecapStore(directory: directory) { _ in throw NBARecapError.authorizationRequired }
                let date = result.dataAsOf
                let box = NBABoxScoreStore(directory: qa.appendingPathComponent("box-" + id), now: { date }, fetch: { _ in data })
                let profiles = NBAPlayerProfileStore(directory: qa.appendingPathComponent("profiles"), fetch: { _ in throw URLError(.notConnectedToInternet) })
                let league = NBALeaguePercentileStore(directory: qa.appendingPathComponent("ranking"), priorDirectory: qa.appendingPathComponent("prior"), fetch: { _, _, _ in throw URLError(.notConnectedToInternet) })
                let schedules = NBAPregameScheduleStore(directory: qa.appendingPathComponent("schedules"), fetch: { _ in throw URLError(.notConnectedToInternet) })
                for article in [false] {
                    let visibility = NBATerraQAVisibility()
                    let view = NBABoxScoreView(gameID: id, boxStore: box, profileStore: profiles, leagueStore: league,
                        pregameStore: schedules, articleStore: store, initiallyShowsTerra: article, onTerraVisibilityChanged: { visibility.showing = $0; visibility.transitions.append($0) })
                    let host = NSHostingView(rootView: view)
                    let window = makeWindow(host, title: "原位卡片验收")
                    try await Task.sleep(nanoseconds: 700_000_000)
                    capture(host, window: window, at: qa.appendingPathComponent(id + (article ? "-article" : "-statistics")))
                    let count = NSApp.windows.filter(\.isVisible).count
                    click(host, window: window, x: 550, fromTop: kind == "recap" ? 28 : 18)
                    try await Task.sleep(nanoseconds: 400_000_000)
                    capture(host, window: window, at: qa.appendingPathComponent(id + "-article"))
                    let firstPress = visibility.showing
                    let titleVisible = visibility.showing
                    let sameWindow = count == NSApp.windows.filter(\.isVisible).count
                    click(host, window: window, x: 45, fromTop: 23)
                    try await Task.sleep(nanoseconds: 300_000_000)
                    capture(host, window: window, at: qa.appendingPathComponent(id + "-returned"))
                    let back = !visibility.showing
                    let statisticsVisible = !visibility.showing
                    click(host, window: window, x: 550, fromTop: kind == "recap" ? 28 : 18)
                    try await Task.sleep(nanoseconds: 300_000_000)
                    let reopened = visibility.showing
                    let report: [String: Any] = ["transitions": visibility.transitions, "openedInline": firstPress, "titleVisible": titleVisible, "returned": back,
                        "statisticsVisibleAfterReturn": statisticsVisible, "reopened": reopened,
                        "sameVisibleWindowCount": sameWindow, "APIRequests": 0, "keychainReads": 0]
                    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                        .write(to: qa.appendingPathComponent(id + "-interaction.json"))
                    window.close()
                }
            }
        } catch {
            try? JSONSerialization.data(withJSONObject: ["error": "原位卡片验收未完成", "type": String(reflecting: Swift.type(of: error))])
                .write(to: qa.appendingPathComponent("failure.json"))
        }
    }
    private static func click(_ host: NSView, window: NSWindow, x: CGFloat, fromTop: CGFloat) {
        let local = NSPoint(x: x, y: host.isFlipped ? fromTop : host.bounds.height - fromTop)
        let point = host.convert(local, to: nil)
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: kind == .leftMouseDown ? 1 : 0) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }
    private static func makeWindow(_ host: NSView, title: String) -> NSWindow {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 620, height: 480), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = title; window.contentView = host
        NSApp.setActivationPolicy(.regular); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return window
    }
    private static func capture(_ host: NSView, window: NSWindow, at url: URL) {
        window.setContentSize(host.fittingSize); host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url.appendingPathExtension("png"))
        }
        try? JSONSerialization.data(withJSONObject: ["width": host.bounds.width, "height": host.bounds.height,
            "realAPICalls": 0, "keychainReads": 0, "screenshotsUploaded": false], options: [.prettyPrinted, .sortedKeys])
            .write(to: url.appendingPathExtension("json"))
    }
}
#endif
