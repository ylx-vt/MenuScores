import AppKit
import SwiftUI

enum NBATerraOptions {
    static let enabledKey = "terraArticlesEnabled"
    static func enabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) == nil || defaults.bool(forKey: enabledKey)
    }
    static func kind(for summary: NBABoxScore, now: Date = Date()) -> NBARecapInput.Kind? {
        let type = summary.match?.status?.type
        if type?.state == "post", type?.completed == true,
           ["STATUS_FINAL", "STATUS_FINAL_OVERTIME"].contains(type?.name ?? "") { return .recap }
        if type?.state == "pre", type?.completed == false, type?.name == "STATUS_SCHEDULED",
           let start = summary.match?.date.flatMap(NBASchedulePolicy.startDate), start > now { return .pregame }
        return nil
    }
}

extension NBATerraRecapStore {
    static var evidenceDirectory: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NBATerraArticles-v2/evidence", isDirectory: true) }
    static let live: NBATerraRecapStore = {
        return NBATerraRecapStore(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NBATerraArticles-v2", isDirectory: true), onSaved: { article in
                guard !AppRuntime.suppressesLiveWork else { return }
                await NBARecapNotificationService.shared.articleReady(article)
            }) { input in
                try await NBATerraAutofill.shared.budgetedGenerate(input)
            }
    }()
}

@MainActor final class NBATerraArticleModel: ObservableObject {
    @Published private(set) var input: NBARecapInput?
    @Published private(set) var article: NBARecap?
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var error: String?
    @Published private(set) var fromCache = false
    @Published private(set) var sourceFresh = false
    let gameID: String
    private let boxStore: NBABoxScoreStore
    private let articles: NBATerraRecapStore
    private let now: @Sendable () -> Date
    private var operation: Task<Void, Never>?
    private var revision = UUID()

    init(gameID: String, boxStore: NBABoxScoreStore = .shared, articles: NBATerraRecapStore = .live,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.gameID = gameID; self.boxStore = boxStore; self.articles = articles; self.now = now
    }
    var title: String { input?.facts.kind.title ?? "Terra 比赛解读" }
    var matchTitle: String {
        input?.facts.teams.map { team in
            team.name + (team.score.map { " \($0)" } ?? (team.side == "home" ? "（主）" : "（客）"))
        }.joined(separator: "  ·  ") ?? "正在确认比赛状态"
    }
    func useSnapshot(_ input: NBARecapInput, article: NBARecap?, fresh: Bool) {
        guard !isLoading else { return }
        accept(input); self.article = article; fromCache = article != nil; sourceFresh = fresh
    }
    func refresh() {
        guard !isLoading, !isRefreshing else { return }
        isRefreshing = true; error = nil
        let current = revision
        operation = Task {
            do {
                let value = try await freshInput()
                guard current == revision, !Task.isCancelled else { return }
                accept(value)
                let saved = await articles.cached(value)
                guard current == revision, !Task.isCancelled else { return }
                article = saved; fromCache = saved != nil; isRefreshing = false
            } catch {
                guard current == revision, !Task.isCancelled else { return }
                sourceFresh = false; isRefreshing = false
                self.error = friendly(error)
                // A changed status must not leave a pregame/final article visible.
                if error is NBARecapError { input = nil; article = nil }
            }
        }
    }
    func generate(enabled: Bool) {
        guard enabled, !isLoading, !isRefreshing, sourceFresh, input != nil else { return }
        isLoading = true; error = nil
        let current = revision
        operation = Task {
            do {
                // Recheck public state before every possible paid request. A
                // pregame view held open across tipoff cannot generate a preview.
                let value = try await freshInput()
                guard current == revision, !Task.isCancelled else { return }
                accept(value)
                let saved = await articles.cached(value, allowLegacy: false)
                let result: NBARecap
                if let saved { result = saved } else { result = try await articles.load(value) }
                guard current == revision, !Task.isCancelled else { return }
                if value.facts.kind == .pregame, let start = value.facts.matchDate.flatMap(NBASchedulePolicy.startDate), start <= now() {
                    invalidateState(); return
                }
                article = result; fromCache = saved != nil; isLoading = false
            } catch {
                guard current == revision, !Task.isCancelled else { return }
                isLoading = false; self.error = friendly(error)
                if let failure = error as? NBARecapError, [.notFinal, .notPregame, .invalidData].contains(failure) {
                    input = nil; article = nil; sourceFresh = false
                }
            }
        }
    }
    func cancel() {
        let activeInput = input, wasLoading = isLoading
        revision = UUID(); operation?.cancel(); operation = nil; isLoading = false; isRefreshing = false
        if wasLoading, let activeInput { Task { await articles.cancel(activeInput) } }
        if wasLoading { error = NBARecapError.cancelled.localizedDescription }
    }
    func invalidateState() {
        cancel(); input = nil; article = nil; sourceFresh = false
        error = "比赛状态已变化或已到计划开赛时间，请刷新比赛后查看。"
    }
    func expirePregame(cacheKey: String) {
        guard let input, input.cacheKey == cacheKey, input.facts.kind == .pregame,
              let start = input.facts.matchDate.flatMap(NBASchedulePolicy.startDate), start <= now() else { return }
        invalidateState()
    }
    private func freshInput() async throws -> NBARecapInput {
        let entry = try await boxStore.load(gameID: gameID, force: true)
        try Task.checkCancellation()
        guard !entry.refreshFailed, !entry.isStale else { throw URLError(.cannotLoadFromNetwork) }
        return try NBARecapInput.makeArticle(data: entry.data, gameID: gameID, dataAsOf: entry.date, now: now())
    }
    private func accept(_ value: NBARecapInput) {
        if input?.cacheKey != value.cacheKey { article = nil; fromCache = false }
        input = value; sourceFresh = true
    }
    private func friendly(_ failure: Error) -> String {
        if failure is NBARecapError || failure is NBAOpenAICredential.Failure || failure is NBAOpenAIPrivateConfiguration.Failure { return failure.localizedDescription }
        return "比赛数据更新失败，请刷新后重试。未发送新的模型请求。"
    }
}

struct NBATerraPresentation {
    let title: String
    let lead: String
    let paragraphs: [String]
    init(article: NBARecap, fallbackTitle: String) {
        title = article.title ?? fallbackTitle
        if let lead = article.lead, let paragraphs = article.paragraphs {
            self.lead = lead; self.paragraphs = paragraphs
        } else {
            // Preserve every word and punctuation in old model output. This is
            // display grouping only, never presented as a new model rewrite.
            var sentences: [String] = [], current = ""
            for char in article.text {
                current.append(char)
                if "。！？".contains(char) { sentences.append(current); current = "" }
            }
            if !current.isEmpty { sentences.append(current) }
            self.lead = sentences.first ?? article.text
            let rest = Array(sentences.dropFirst())
            let strideSize = max(1, Int(ceil(Double(rest.count) / 3)))
            self.paragraphs = stride(from: 0, to: rest.count, by: strideSize).map {
                rest[$0..<min($0 + strideSize, rest.count)].joined()
            }
        }
    }
}

/// Content only: hosted inside the original menu card, never in a result window.
struct NBATerraArticleView: View {
    @ObservedObject var model: NBATerraArticleModel
    var onBack: (() -> Void)? = nil
    @AppStorage(NBATerraOptions.enabledKey) private var enabled = true
    @State private var showSources = false
    @State private var automaticJob: NBATerraAutofill.Job?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let onBack {
                    Button("技术统计", action: onBack).buttonStyle(.borderless).foregroundStyle(.secondary)
                }
                Text(model.title).fontWeight(.medium).padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Color.purple.opacity(0.12), in: Capsule())
                Spacer()
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(model.isLoading || model.isRefreshing)
                    .help("刷新数据与缓存，不调用模型")
            }.font(.system(size: 11))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if showSources, let input = model.input {
                        HStack {
                            Text("数据与来源").font(.system(size: 15, weight: .semibold))
                            Spacer(); Button("返回正文") { showSources = false }.buttonStyle(.borderless)
                        }
                        Link("ESPN 比赛原始数据", destination: input.sourceURL).font(.system(size: 12))
                        Text(input.facts.limitations.joined(separator: "\n")).font(.system(size: 12)).foregroundStyle(.secondary)
                        Text((try? String(decoding: input.json(), as: UTF8.self)) ?? "")
                            .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    } else if let article = model.article {
                        let presentation = NBATerraPresentation(article: article, fallbackTitle: model.title)
                        Text(presentation.title).font(.system(size: 15, weight: .semibold))
                        Text(presentation.lead).font(.system(size: 13, weight: .medium)).lineSpacing(4)
                        ForEach(presentation.paragraphs.indices, id: \.self) { index in
                            Text(presentation.paragraphs[index]).font(.system(size: 12.5)).lineSpacing(4)
                        }
                        .textSelection(.enabled)
                        if article.isLegacy {
                            Text("旧版文案 · 仅调整显示分段，尚未用新提示词改写")
                                .font(.system(size: 11)).foregroundStyle(.orange)
                        }
                    } else {
                        Text(model.matchTitle).font(.system(size: 15, weight: .semibold))
                        if model.isLoading || model.isRefreshing || automaticJob?.state == "running" {
                            HStack { ProgressView().controlSize(.small); Text(model.isRefreshing ? "正在读取比赛数据和缓存…" : "Terra 正在准备内容…") }
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        } else {
                            Text(automaticJob?.message ?? "本场内容尚未准备，可手动生成。")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
            }
            if let error = model.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 4) {
                if let article = model.article {
                    Text("\(article.model) · 生成于 \(article.generatedAt.formatted(.dateTime.month().day().hour().minute()))\(model.fromCache ? " · 缓存" : "")")
                }
                if let input = model.input {
                    Text("数据截至 \(input.dataAsOf.formatted(.dateTime.month().day().hour().minute())) · \(input.facts.kind == .pregame ? "仅据赛程、战绩及赛季统计" : "仅据比分、技术统计及可核逐节数据")")
                }
                HStack {
                    if model.isLoading || model.isRefreshing {
                        Button("取消") { model.cancel() }
                    } else if model.article?.isLegacy == true {
                        Text("待新版文案").foregroundStyle(.orange)
                        Button("更新文案") { model.generate(enabled: enabled) }
                            .disabled(!enabled || !model.sourceFresh)
                    } else if model.article == nil {
                        Button("生成" + (model.input?.facts.kind.title ?? "比赛解读")) { model.generate(enabled: enabled) }
                            .disabled(!enabled || !model.sourceFresh || automaticJob?.state == "running")
                    }
                    Spacer()
                    Button(showSources ? "正文" : "来源") { showSources.toggle() }.disabled(model.input == nil)
                }.buttonStyle(.borderless)
                if model.article?.isLegacy == true || model.article == nil {
                    Text("生成会调用 API 并计入每日预算；读取缓存不扣费。")
                }
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }.tint(.purple)
        .onAppear { if model.input == nil, !model.isRefreshing { model.refresh() } }
        .onChange(of: enabled) { if !$0 { model.cancel() } }
        .onReceive(NotificationCenter.default.publisher(for: .terraArticlePrepared).receive(on: RunLoop.main)) { event in
            if event.object as? String == model.gameID { model.refresh() }
        }
        .task {
            while !Task.isCancelled {
                let ledger = await NBATerraAutofill.shared.snapshot()
                automaticJob = ledger.jobs.values.first { $0.gameID == model.gameID && $0.kind == model.input?.facts.kind }
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            }
        }
        .task(id: model.input?.cacheKey) {
            guard let input = model.input, input.facts.kind == .pregame,
                  let start = input.facts.matchDate.flatMap(NBASchedulePolicy.startDate) else { return }
            while !Task.isCancelled, start > Date() {
                do { try await Task.sleep(nanoseconds: UInt64(min(60, max(0.01, start.timeIntervalSinceNow)) * 1_000_000_000)) }
                catch { return }
            }
            if !Task.isCancelled { model.expirePregame(cacheKey: input.cacheKey) }
        }
    }
}
