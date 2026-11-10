#if DEBUG
import AppKit
import SwiftUI

/// Offline native verification only. Release has no preview entry point.
final class NBARestorationOffline: URLProtocol, @unchecked Sendable {
    static var directory: URL {
        let args = ProcessInfo.processInfo.arguments
        let index = args.firstIndex(of: "--restoration-preview")!
        return URL(fileURLWithPath: args[index + 1], isDirectory: true)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

@MainActor final class NBARestorationPreview: NSObject {
    static let shared = NBARestorationPreview()
    private var window: NSWindow?
    private var host: NSView?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var roots: [String: NBABoxScoreView] = [:]
    private var selected = "final"

    func show() {
        let root = NBARestorationOffline.directory
        let profile = NBAPlayerProfileStore(directory: root.appendingPathComponent("profiles"), fetch: { _ in throw URLError(.notConnectedToInternet) })
        let league = NBALeaguePercentileStore(directory: root.appendingPathComponent("ranking"), priorDirectory: root.appendingPathComponent("prior"), fetch: { _, _, _ in throw URLError(.notConnectedToInternet) })
        let pregame = NBAPregameScheduleStore(directory: root.appendingPathComponent("schedules"), fetch: { _ in throw URLError(.notConnectedToInternet) })
        for name in ["final", "halftime", "live", "pregame", "missing"] {
            guard let data = try? Data(contentsOf: root.appendingPathComponent(name + ".json")),
                  let summary = try? JSONDecoder().decode(NBABoxScore.self, from: data), let id = summary.header?.id else { continue }
            let store = NBABoxScoreStore(directory: root.appendingPathComponent("box-" + name), fetch: { _ in data })
            roots[name] = NBABoxScoreView(gameID: id, boxStore: store, profileStore: profile, leagueStore: league, pregameStore: pregame)
        }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 620, height: 464), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "MenuScores · 原详情恢复验收（归档数据）"
        window.isReleasedWhenClosed = false; self.window = window
        let menu = NSMenu()
        for name in ["final", "halftime", "live", "pregame", "missing"] {
            let item = NSMenuItem(title: name, action: #selector(changeFixture(_:)), keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        for title in ["浅色", "深色", "贴合原尺寸", "保存本地图", "菜单栏详情"] {
            let item = NSMenuItem(title: title, action: #selector(action(_:)), keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "恢复验收"; statusItem?.menu = menu
        let mainItem = NSMenuItem(title: "恢复验收", action: nil, keyEquivalent: "")
        mainItem.submenu = menu.copy() as? NSMenu
        NSApp.mainMenu?.addItem(mainItem)
        let accessory = NSTitlebarAccessoryViewController()
        let picker = NSPopUpButton(frame: .init(x: 0, y: 0, width: 140, height: 26), pullsDown: true)
        picker.menu = menu.copy() as? NSMenu
        accessory.view = picker; accessory.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(accessory)
        display("final")
        NSApp.setActivationPolicy(.regular); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func changeFixture(_ item: NSMenuItem) { display(item.title) }
    private func display(_ name: String) {
        guard let root = roots[name] else { return }
        selected = name
        let host = NSHostingView(rootView: root.id(name)); self.host = host; window?.contentView = host
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.fit() }
    }
    private func fit() {
        guard let host else { return }
        window?.setContentSize(host.fittingSize)
    }
    @objc private func action(_ item: NSMenuItem) {
        switch item.title {
        case "浅色": window?.appearance = NSAppearance(named: .aqua)
        case "深色": window?.appearance = NSAppearance(named: .darkAqua)
        case "贴合原尺寸": fit()
        case "菜单栏详情":
            guard let button = statusItem?.button, let root = roots[selected] else { return }
            popover.behavior = .transient; popover.animates = false
            popover.contentViewController = NSHostingController(rootView: root.id("popover-" + selected))
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        default: save()
        }
    }
    private func save() {
        guard let host, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let name = selected + (window?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "-dark" : "-light")
        try? bitmap.representation(using: .png, properties: [:])?.write(to: NBARestorationOffline.directory.appendingPathComponent(name + ".png"))
        let evidence: [String: Any] = ["fixture": selected, "width": host.bounds.width, "height": host.bounds.height, "baseline": "2.4.3(16)", "restoredView": "exact retained source"]
        try? JSONSerialization.data(withJSONObject: evidence, options: .prettyPrinted).write(to: NBARestorationOffline.directory.appendingPathComponent(name + ".json"))
    }
}
#endif
