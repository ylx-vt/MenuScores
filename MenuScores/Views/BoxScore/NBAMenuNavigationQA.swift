#if DEBUG
import AppKit
import SwiftUI

/// Production match rows and cached-article reader with isolated frozen data.
@MainActor enum NBAMenuNavigationQA {
    struct Fixture: Decodable, Sendable {
        let games: [Event]
        let ledger: NBATerraAutofill.Ledger
        let articles: [NBARecap]
    }
    actor FixtureLedger {
        var ledger: NBATerraAutofill.Ledger
        init(_ ledger: NBATerraAutofill.Ledger) { self.ledger = ledger }
        func snapshot() -> NBATerraAutofill.Ledger { ledger }
        func finish() { for key in ledger.jobs.keys where ledger.jobs[key]?.state == "running" { ledger.jobs[key]?.state = "done" } }
    }
    static var window: NSWindow?
    static func run() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--menu-navigation-qa"), args.indices.contains(index + 1) else { return }
        let root = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        do {
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("fixture.json")))
            let ledger = FixtureLedger(fixture.ledger)
            let status = NBAArticleMenuStatus(snapshot: { await ledger.snapshot() }, read: { id, _, kind in
                fixture.articles.filter { $0.gameID == id && $0.kind == kind }.max { $0.generatedAt < $1.generatedAt }
            })
            let model = GamesListView(); model.games = fixture.games
            let view = Preview(model: model, status: status, ledger: ledger, showTestControls: args.contains("--simulate-states"),
                               maxVisibleGames: args.contains("--scrollbar-qa") ? 4 : 8)
            let compareDensity = args.contains("--density-comparison")
            let preview = NSWindow(contentRect: NSRect(x: 0, y: 0, width: compareDensity ? 640 : 420, height: compareDensity ? 640 : 334),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            preview.title = "紧凑比赛列表预览"; preview.isReleasedWhenClosed = false
            preview.contentView = NSHostingView(rootView: view); window = preview
            NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
            preview.center(); preview.makeKeyAndOrderFront(nil)
        } catch { NSApp.terminate(nil) }
    }
    private struct Preview: View {
        @ObservedObject var model: GamesListView
        @ObservedObject var status: NBAArticleMenuStatus
        let ledger: FixtureLedger
        let showTestControls: Bool
        let maxVisibleGames: Int
        @State private var article: NBARecap?
        @State private var pin = ""
        @State private var history = false
        var body: some View {
            NBAMainMenuNavigation(showingDetail: Binding(get: { article != nil }, set: { if !$0 { article = nil } }), showingHistory: $history,
                                  showSettings: { SettingsWindowController.shared.showWindow() }) {
                if let article {
                    NBARecapNotificationReader(article: article) { self.article = nil }.frame(width: 600, height: 540)
                } else {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("NBA").font(.headline)
                        NBAFlatMenu(viewModel: model, selectedGameID: pin, onSelect: { pin = $0.id }, heading: "比赛", maxVisibleGames: maxVisibleGames,
                                    onOpenArticle: { _, result in article = result }, articleStatus: status)
                        HStack {
                            Button("设置") { SettingsWindowController.shared.showWindow() }
                            Spacer()
                            if showTestControls {
                                Button("模拟准备完成") { Task { await ledger.finish(); await status.refresh(games: model.games) } }
                            }
                        }.buttonStyle(.borderless).font(.caption)
                    }.padding(12).frame(width: 420)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .onChange(of: article?.cacheKey) { key in
                    window?.setContentSize(key == nil ? NSSize(width: 420, height: 334) : NSSize(width: 620, height: 600))
                }
        }
    }
}
#endif
