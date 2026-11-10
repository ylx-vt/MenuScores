import SwiftUI
import Combine

@MainActor final class NBAReviewPanelModel: ObservableObject {
    enum Route: String, CaseIterable { case score, recap, evidence, question, statistics }
    let gameID: String
    let boxes: NBABoxScoreStore
    let articles: NBATerraRecapStore
    let articleModel: NBATerraArticleModel
    @Published var route: Route = .score
    @Published var selectedSegmentID: String? { didSet { queueHistorySave() } }
    @Published var selectedPointID: String? { didSet { queueHistorySave() } }
    @Published var draft = "" { didSet { queueHistorySave() } }
    @Published var showSources = false
    @Published var showFullArticle = false
    @Published var statisticsTeamID: String?
    @Published private(set) var evidence: NBAReviewEvidence?
    @Published private(set) var turns: [NBAReviewTurn] = []
    @Published private(set) var isLoading = false
    @Published private(set) var asking = false
    @Published private(set) var error: String?
    @Published private(set) var fromCache = false
    @Published private(set) var questionBack: Route = .recap
    @Published private(set) var historyError: String?
    @Published private(set) var historyAttempt: NBAReviewConversationStore.Attempt?
    private let historyStore: NBAReviewConversationStore?
    private var historyLoaded = false, historyBlocked = false
    private var historyRevision = 0
    private var historySaveTask: Task<Void, Never>?
    private var subscription: AnyCancellable?
    private var operation: Task<Void, Never>?
    private var questionRevision = UUID()
    private let questions: NBAReviewQuestionStore
    private let ask: @Sendable (NBAReviewEvidence, String?, String?, String, [NBAReviewTurn]) async throws -> NBAReviewAnswer
    var questionsAllowed: Bool { evidence?.input != nil && NBATerraOptions.enabled() && !historyBlocked }
    var hasConversation: Bool { !turns.isEmpty || historyAttempt != nil }
    var conversationCount: Int { turns.count + (historyAttempt == nil ? 0 : 1) }
    var segment: NBAReviewEvidence.Segment? { evidence?.segments.first(where: { $0.id == selectedSegmentID }) ?? evidence?.segments.first }
    init(gameID: String, boxes: NBABoxScoreStore = .shared, articles: NBATerraRecapStore = .live,
         questions: NBAReviewQuestionStore = .shared,
         history: NBAReviewConversationStore? = .live,
         ask: (@Sendable (NBAReviewEvidence, String?, String?, String, [NBAReviewTurn]) async throws -> NBAReviewAnswer)? = nil) {
        self.gameID = gameID; self.boxes = boxes; self.articles = articles; self.questions = questions
        self.historyStore = history
        articleModel = NBATerraArticleModel(gameID: gameID, boxStore: boxes, articles: articles)
        self.ask = ask ?? { evidence, segment, pointID, question, turns in
            try await NBAReviewResearch(auditDirectory:NBAReviewQuestionClient.evidenceDirectory.deletingLastPathComponent().appendingPathComponent("queries")).answer(evidence:evidence,segmentID:segment,pointID:pointID,question:question,turns:turns,boxes:boxes)
        }
        subscription = articleModel.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }
    func load(force: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true; if historyAttempt == nil { error = nil }; defer { isLoading = false }
        if !historyLoaded { await restoreHistory() }
        if let old = await boxes.cached(gameID: gameID) { await apply(old) }
        do { await apply(try await boxes.load(gameID: gameID, force: force)) }
        catch { self.error = evidence == nil ? "比赛资料暂时无法读取，请重试。" : "更新失败，正在显示已缓存资料。" }
    }
    private func apply(_ entry: NBABoxScoreStore.Entry) async {
        do {
            let value = try NBAReviewEvidence.make(data: entry.data, gameID: gameID, dataAsOf: entry.date)
            guard !Task.isCancelled else { return }
            evidence = value; fromCache = entry.isStale || entry.refreshFailed
            if selectedSegmentID == nil || !value.segments.contains(where: { $0.id == selectedSegmentID }) {
                selectedSegmentID = value.segments.first(where: { $0.id == "focus" })?.id ?? value.segments.first?.id
            }
            if let input = value.input {
                let cached = await articles.cached(input)
                articleModel.useSnapshot(input, article: cached, fresh: !entry.refreshFailed && !entry.isStale)
            }
            // Running questions own their frozen evidence. Refreshing or
            // reopening the view must not cancel a paid task or discard it.
        } catch { self.error = "比赛资料未通过身份或格式检查，暂不展示。" }
    }
    func openEvidence(_ segment: NBAReviewEvidence.Segment) { selectedSegmentID = segment.id; selectedPointID = nil; showSources = false; route = .evidence }
    func submit(force: Bool = false) {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asking, let evidence, !question.isEmpty, question.count <= 800, questionsAllowed else { return }
        guard !NBAReviewPrivacy.containsCredential(question) else { error = "请勿在比赛追问中输入密钥或密码；该内容不会保存或发送。"; return }
        questionBack = route == .evidence ? .evidence : route == .question ? questionBack : .recap
        route = .question; error = nil; showSources = false
        if !force, let last = turns.last, last.question == question, !last.answer.searched || Date().timeIntervalSince(last.answer.generatedAt) < 300 { draft = ""; return }
        let revision = UUID(); questionRevision = revision
        let history = turns, segmentID = selectedSegmentID, pointID = selectedPointID, questions = self.questions, ask = self.ask
        let contextLabel = segment.map { $0.time + " · " + $0.headline }
        let askedAt = Date()
        historyAttempt = .init(id: revision, question: question, startedAt: askedAt, state: "pending", contextLabel: contextLabel, evidenceFingerprint: evidence.fingerprint)
        asking = true
        operation = Task {
            do {
                // Persist the question before any paid request. A disk error
                // must not silently lose a paid conversation.
                try await persistHistory()
                try Task.checkCancellation()
                let key = NBAReviewQuestionClient.key(evidence: evidence, segmentID: segmentID, question: question, turns: history, pointID: pointID)
                let answer = try await questions.answer(key: key, gameID: gameID) { try await ask(evidence, segmentID, pointID, question, history) }
                guard questionRevision == revision, !Task.isCancelled, answer.gameID == gameID else { return }
                var turn = NBAReviewTurn(question: question, answer: answer, contextLabel: answer.localEvidence?.queryScope ?? contextLabel)
                turn.id = revision; turn.askedAt = askedAt; turn.evidenceFingerprint = evidence.fingerprint; turn.selectedSegmentID = segmentID; turn.selectedPointID = pointID
                turns.append(turn); historyAttempt = nil
                if draft.trimmingCharacters(in: .whitespacesAndNewlines) == question { draft = "" }
                asking = false
                do { try await persistHistory() } catch { historyError = error.localizedDescription }
            } catch {
                guard questionRevision == revision, !Task.isCancelled else { return }
                asking = false
                self.error = (error as? LocalizedError)?.errorDescription ?? "请求未完成，未自动重试。请稍后手动重试。"
                historyAttempt?.state = "failed"
                historyAttempt?.errorMessage = self.error
                do { try await persistHistory() } catch { historyError = error.localizedDescription }
            }
        }
    }
    func cancelQuestion() {
        questionRevision = UUID(); operation?.cancel(); operation = nil; asking = false
        historyAttempt?.state = "cancelled"; queueHistorySave(immediately:true)
        error = "已取消本地请求，服务器可能已处理；未确认费用仍保留。"
        historyAttempt?.errorMessage = error
    }
    func leave() { queueHistorySave(immediately: true) }
    func openConversation() { questionBack = .recap; showSources = false; route = .question }
    func retry(_ turn: NBAReviewTurn) { guard turn.questionKnown, !asking else { return }; draft = turn.question; submit(force:true) }
    func retryHistorySave() { queueHistorySave(immediately: true) }
    func retryAttempt() { guard !asking,let attempt = historyAttempt else { return };draft = attempt.question;submit(force:true) }
    private func restoreHistory() async {
        guard let historyStore else { historyLoaded = true; return }
        do {
            let saved = try await historyStore.load(gameID: gameID)
            turns = saved.turns; draft = saved.draft; selectedSegmentID = saved.selectedSegmentID; selectedPointID = saved.selectedPointID
            historyRevision = saved.revision; historyAttempt = saved.attempt
            if historyAttempt?.state == "pending" { historyAttempt?.state = "interrupted" }
            if let attempt = historyAttempt {
                if draft.isEmpty { draft = attempt.question }
                error = attempt.errorMessage ?? "上次问题\(attempt.state == "cancelled" ? "已取消" : "未完成")，原问已保留为草稿，未自动重发。"
            }
            historyLoaded = true
            try await persistHistory()
        } catch { historyLoaded = true; historyBlocked = true; historyError = error.localizedDescription }
    }
    private func queueHistorySave(immediately: Bool = false) {
        guard historyLoaded, historyStore != nil, !historyBlocked else { return }
        historySaveTask?.cancel()
        historySaveTask = Task {
            do {
                if !immediately { try await Task.sleep(nanoseconds: 150_000_000) }
                try Task.checkCancellation(); try await persistHistory()
            } catch is CancellationError {} catch { historyError = error.localizedDescription }
        }
    }
    private func persistHistory() async throws {
        guard let historyStore, historyLoaded, !historyBlocked else { return }
        historyRevision += 1
        var value = NBAReviewConversationStore.Document(gameID: gameID)
        value.revision = historyRevision; value.turns = turns; value.draft = draft
        value.selectedSegmentID = selectedSegmentID; value.selectedPointID = selectedPointID; value.attempt = historyAttempt; value.updatedAt = Date()
        try await historyStore.save(value); historyError = nil
    }
}

@MainActor final class NBAReviewSessions {
    static let shared = NBAReviewSessions()
    private var models: [String: NBAReviewPanelModel] = [:]
    private let create: @MainActor (String) -> NBAReviewPanelModel
    init(create: (@MainActor (String) -> NBAReviewPanelModel)? = nil) { self.create = create ?? { NBAReviewPanelModel(gameID:$0) } }
    static func model(gameID: String) -> NBAReviewPanelModel { shared.session(gameID:gameID) }
    func session(gameID: String) -> NBAReviewPanelModel {
        if let existing = models[gameID] { return existing }
        let value = create(gameID); models[gameID] = value; return value
    }
}
