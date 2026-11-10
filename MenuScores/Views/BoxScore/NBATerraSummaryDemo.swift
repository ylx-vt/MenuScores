#if DEBUG
import AppKit
import SwiftUI

@MainActor final class NBARecapDemoModel: ObservableObject {
    @Published private(set) var input: NBARecapInput?
    @Published private(set) var scoreTitle = "载入比赛…"
    @Published private(set) var eligibilityMessage: String?
    @Published private(set) var recap: NBARecap?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var fromCache = false
    @Published private(set) var selectedFixture = "final"
    let credentialPresent: Bool
    let authorized: Bool
    let directory: URL
    private let store: NBATerraRecapStore
    private var task: Task<Void, Never>?
    private var revision = UUID()

    init(directory: URL, store: NBATerraRecapStore? = nil, authorized: Bool = false, credentialPresent: Bool? = nil) {
        self.directory = directory; self.authorized = authorized
        self.credentialPresent = credentialPresent ?? NBAOpenAIPrivateConfiguration.shared.isConfigured
        let client = NBATerraClient(authorized: authorized)
        self.store = store ?? NBATerraRecapStore(directory: URL(fileURLWithPath: "/tmp/MenuScores-build/TerraDemo/recaps", isDirectory: true)) {
            try await client.generate($0)
        }
    }
    func select(_ fixture: String) {
        cancel(showMessage: false)
        selectedFixture = fixture
        input = nil; recap = nil; eligibilityMessage = nil; errorMessage = nil; fromCache = false
        do {
            var data = try Data(contentsOf: directory.appendingPathComponent("NBA-match-\(fixture == "missing" ? "final" : fixture).json"))
            if fixture == "missing", var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               var header = root["header"] as? [String: Any], var matches = header["competitions"] as? [[String: Any]],
               var match = matches.first, var competitors = match["competitors"] as? [[String: Any]] {
                // Explicit degraded-data scenario, not an invented result.
                root["boxscore"] = nil; root["plays"] = nil
                for i in competitors.indices { competitors[i]["linescores"] = nil }
                match["competitors"] = competitors; matches[0] = match; header["competitions"] = matches; root["header"] = header
                data = try JSONSerialization.data(withJSONObject: root)
            }
            let summary = try JSONDecoder().decode(NBABoxScore.self, from: data)
            scoreTitle = summary.scoreTitle
            guard let id = summary.header?.id else { throw NBARecapError.invalidData }
            let manifestData = try Data(contentsOf: directory.appendingPathComponent("NBA-match-provenance.json"))
            let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: [String: Any]]
            let dateString = manifest?[fixture == "missing" ? "final" : fixture]?["cachedAtUTC"] as? String
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let dateString, let date = formatter.date(from: dateString) else { throw NBARecapError.invalidData }
            let value = try NBARecapInput.make(data: data, gameID: id, dataAsOf: date)
            input = value
            let current = revision
            task = Task {
                let saved = await store.cached(value)
                guard current == revision, !Task.isCancelled else { return }
                if let saved { recap = saved; fromCache = true }
            }
        } catch {
            eligibilityMessage = (error as? NBARecapError)?.localizedDescription ?? "无法读取归档比赛文件，请使用项目的 demo 启动脚本。"
        }
    }
    func generate() {
        guard !isLoading, let input else { return }
        if recap != nil { fromCache = true; return }
        errorMessage = nil
        guard credentialPresent else { errorMessage = NBARecapError.missingCredential.localizedDescription; return }
        guard authorized else { errorMessage = NBARecapError.authorizationRequired.localizedDescription; return }
        isLoading = true
        let current = revision
        task = Task {
            do {
                let result = try await store.load(input)
                guard current == revision, !Task.isCancelled else { return }
                recap = result; isLoading = false; fromCache = false
            } catch {
                guard current == revision, !Task.isCancelled else { return }
                isLoading = false; errorMessage = error.localizedDescription
            }
        }
    }
    func cancel(showMessage: Bool = true) {
        let wasLoading = isLoading
        revision = UUID(); task?.cancel(); task = nil; isLoading = false
        if let input, wasLoading { Task { await store.cancel(input) } }
        if showMessage, wasLoading { errorMessage = NBARecapError.cancelled.localizedDescription }
    }
}

struct NBATerraRecapDemoView: View {
    @StateObject var model: NBARecapDemoModel
    @State private var showsInput = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("赛后总结", systemImage: "text.alignleft").font(.title2.bold())
                Spacer()
                Text("TERRA DEMO").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            Picker("归档比赛", selection: Binding(get: { model.selectedFixture }, set: { model.select($0) })) {
                Text("已完赛").tag("final")
                Text("进行中").tag("live")
                Text("统计缺失").tag("missing")
            }.pickerStyle(.segmented).disabled(model.isLoading)
            Text(model.scoreTitle).font(.headline).textSelection(.enabled)
            if let input = model.input {
                HStack {
                    Label("已完赛 · 归档数据", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    Spacer()
                    Text(input.dataAsOf, format: .dateTime.year().month().day().hour().minute().second().timeZone())
                }.font(.caption)
            }
            Group {
                if let recap = model.recap {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(recap.text).font(.system(size: 14)).lineSpacing(6).textSelection(.enabled)
                        Divider()
                        Text("\(recap.model) · \(model.fromCache ? "已缓存" : "API 生成") · \(recap.generatedAt.formatted())")
                        if let tokensIn = recap.inputTokens, let tokensOut = recap.outputTokens, let cost = recap.workflowEstimatedUSD {
                            Text("终稿输入 \(tokensIn) / 输出 \(tokensOut) tokens · 全流程估算 $\(String(format: "%.5f", cost))")
                        }
                        Text("依据：\(recap.evidenceIDs.joined(separator: "、"))")
                    }
                } else if model.isLoading {
                    HStack { ProgressView(); Text("Terra 正在生成赛后总结…"); Spacer(); Button("取消") { model.cancel() } }
                        .frame(minHeight: 120)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.eligibilityMessage ?? "点击生成本场的中文赛后总结。")
                        if model.input != nil { Text("比分、统计差距和主要球员，3–5 句话。只在有逐节证据时描述走势。") }
                        Text("尚未生成 Terra 内容").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .font(.caption)
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(model.recap != nil ? "已生成 · 使用缓存" : model.errorMessage == nil ? "生成赛后总结" : "重试生成") { model.generate() }
                    .buttonStyle(.borderedProminent).disabled(model.input == nil || model.isLoading || model.recap != nil)
                if model.input != nil { Button("查看输入与来源") { showsInput.toggle() } }
                Spacer()
            }
            Text(model.credentialPresent ? (model.authorized ? "真实 API 已启用 · 仅点击时请求 · 不自动重试" : "已检测到本机配置 · 此 demo 尚未启用真实 API") : "未配置 API 凭据 · 当前不会发出模型请求")
                .font(.caption).foregroundStyle(.secondary)
            if let input = model.input {
                Link("ESPN 原始数据 · \(input.facts.gameID)", destination: input.sourceURL).font(.caption)
                Text(input.facts.limitations.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary)
            }
            Text("隔离开发入口 · 原小看板保持不变").font(.caption2).foregroundStyle(.tertiary)
        }.padding(24).frame(width: 620)
        .onAppear { model.select(model.selectedFixture) }
        .onDisappear { model.cancel(showMessage: false) }
        .sheet(isPresented: $showsInput) {
            VStack(alignment: .leading, spacing: 12) {
                Text("发送内容预览").font(.headline)
                Text("只发送下列公开比赛事实和固定写作指令；不包含设置、收藏或账户数据。")
                ScrollView { Text(model.input.flatMap { try? String(decoding: $0.json(), as: UTF8.self) } ?? "")
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                Button("关闭") { showsInput = false }.keyboardShortcut(.cancelAction)
            }.padding(20).frame(width: 580, height: 420)
        }
    }
}

@MainActor final class NBATerraSummaryDemo: NSObject, NSWindowDelegate {
    static let shared = NBATerraSummaryDemo()
    private var window: NSWindow?
    func show() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--terra-summary-demo"), args.indices.contains(index + 1) else { return }
        let directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        let model = NBARecapDemoModel(directory: directory, authorized: args.contains("--terra-api-authorized"))
        let host = NSHostingView(rootView: NBATerraRecapDemoView(model: model))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 620, height: 600), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "MenuScores · Terra 赛后总结 Demo"
        window.isReleasedWhenClosed = false; window.delegate = self; window.contentView = host; self.window = window
        NSApp.setActivationPolicy(.regular); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { window.setContentSize(host.fittingSize) }
        // Local-only native rendering evidence. Never uploads screenshots.
        if let captureIndex = args.firstIndex(of: "--terra-demo-capture"), args.indices.contains(captureIndex + 1), !model.authorized {
            let captureDirectory = URL(fileURLWithPath: args[captureIndex + 1], isDirectory: true)
            Task {
                try? FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
                for (name, selection) in [("final", "final"), ("live", "live"), ("missing", "missing"), ("credential-error", "final")] {
                    model.select(selection)
                    if name == "credential-error" { model.generate() }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    window.setContentSize(host.fittingSize)
                    host.layoutSubtreeIfNeeded()
                    if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        try? bitmap.representation(using: .png, properties: [:])?.write(to: captureDirectory.appendingPathComponent(name + ".png"))
                    }
                    let evidence: [String: Any] = ["scenario": name, "width": host.bounds.width, "height": host.bounds.height,
                        "eligible": model.input != nil, "credentialPresent": model.credentialPresent, "authorized": model.authorized,
                        "hasRecap": model.recap != nil, "message": model.errorMessage ?? model.eligibilityMessage ?? "", "realAPICalls": 0]
                    try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: captureDirectory.appendingPathComponent(name + ".json"))
                }
                model.select("final")
                window.setContentSize(host.fittingSize)
            }
        }
    }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
}
#endif
