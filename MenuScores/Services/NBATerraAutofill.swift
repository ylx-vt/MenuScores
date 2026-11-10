import Foundation

extension Notification.Name { static let terraArticlePrepared = Notification.Name("MenuScores.TerraArticlePrepared") }

/// Runs inside the existing app lifecycle. Serial, persistent and budgeted.
/// No system task, daemon, timer or automatic retry is created.
actor NBATerraAutofill {
    static let shared = NBATerraAutofill()
    static let dailyLimitUSD = 5.0
    static let dailyLimitText = "5.00"
    struct Job: Codable, Sendable {
        var gameID: String
        var title: String
        var kind: NBARecapInput.Kind
        var fingerprint: String
        var state: String
        var message: String
        var attempts: Int
        var date: Date
        var estimatedUSD: Double
        var requestID: String?
        var editorialVersion: Int? = nil
        var usageKnown: Bool? = nil
        var wordingRepairAttempted: Bool? = nil
        var budgetLimitUSD: Double? = nil
        var editorialRequired: Bool? = nil
        var completedPasses: Int? = nil
        var generationRequests: Int? = nil
        var draftRequestID: String? = nil
        var draftEstimatedUSD: Double? = nil
        var draftUsageKnown: Bool? = nil
        var requestDay: String? = nil
        var passReservedUSD: Double? = nil
        var passEstimatedUSD: Double? = nil
        var passStartedAt: Date? = nil
        var passModel: String? = nil
    }
    struct ReviewOperation: Codable, Sendable {
        var gameID: String; var day: String; var startedAt: Date; var state: String
        var reservedUSD: Double; var actualUSD: Double?; var requestID: String?; var usage: NBAReviewUsage?
    }
    struct Ledger: Codable, Sendable {
        var day = ""
        var spentUSD = 0.0
        var seeded = false
        var jobs: [String: Job] = [:]
        var approvedRoundLimitUSD: Double? = nil
        var historicalUnconfirmedUSD: Double? = nil
        var tokenCountRequests: Int? = nil
        // Spending belongs to the Beijing day on which a request was sent.
        // Keep prior reservations, including unknown outcomes, across midnight.
        var dailySpendUSD: [String: Double]? = nil
        var reviewOperations: [String: ReviewOperation]? = nil
    }
    typealias Count = @Sendable (NBARecapInput) async throws -> Int
    typealias Generate = @Sendable (NBARecapInput, Int) async throws -> NBARecap
    typealias EditCount = @Sendable (NBARecapInput, NBARecap) async throws -> Int
    typealias Edit = @Sendable (NBARecapInput, NBARecap, Int) async throws -> NBARecap
    private var ledger: Ledger
    private let ledgerReadable: Bool
    private let file: URL
    private let boxes: NBABoxScoreStore
    private let articles: NBATerraRecapStore
    private let count: Count
    private let enabled: @Sendable () -> Bool
    private let generate: Generate
    private let editCount: EditCount
    private let edit: Edit?
    private var worker: Task<Void, Never>?
    private var nextScan = Date.distantPast
    private var processing = false
    private var activeInput: NBARecapInput?
    private let clock: @Sendable () -> Date
    private var networkBusy = false
    private var networkWaiters: [CheckedContinuation<Void, Never>] = []
    private var paidTail: Task<NBARecap, Error>?
    private var paidTasks: [String: (UUID, Task<NBARecap, Error>)] = [:]

    init(file: URL? = nil, boxes: NBABoxScoreStore = .shared, articles: NBATerraRecapStore = .live,
         count: Count? = nil, generate: Generate? = nil, editCount: EditCount? = nil, edit: Edit? = nil,
         clock: @escaping @Sendable () -> Date = { Date() },
         enabled: @escaping @Sendable () -> Bool = {
             NBATerraOptions.enabled() && (UserDefaults.standard.object(forKey: "terraAutomaticEnabled") == nil || UserDefaults.standard.bool(forKey: "terraAutomaticEnabled"))
         }) {
        let location = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MenuScores/TerraAutofill-v1.json")
        self.file = location; self.boxes = boxes; self.articles = articles; self.enabled = enabled; self.clock = clock
        self.count = count ?? { try await NBATerraClient(authorized: true).inputTokenCount($0) }
        self.generate = generate ?? { input, outputLimit in
            let client = NBATerraClient(authorized: true, observe: { data, response in
                NBATerraClient.savePublicEvidence(data, response: response, input: input, directory: NBATerraRecapStore.evidenceDirectory,
                                                 suffix: input.facts.kind == .recap ? "-draft" : "")
            }, outputLimit: outputLimit)
            return try await client.generate(input)
        }
        self.editCount = editCount ?? { input, draft in
            try await NBATerraClient(authorized: true, requestModel: NBATerraClient.editorialModel)
                .inputTokenCount(input, editorialNote: NBATerraClient.editorialReviewNote(draft))
        }
        // A supplied test transport stays single-pass unless an editor is also
        // supplied. Production recaps always use the independent editor.
        self.edit = edit ?? (generate == nil ? { input, draft, outputLimit in
            let client = NBATerraClient(authorized: true, observe: { data, response in
                NBATerraClient.savePublicEvidence(data, response: response, input: input, directory: NBATerraRecapStore.evidenceDirectory)
            }, outputLimit: outputLimit, requestModel: NBATerraClient.editorialModel)
            return try await client.generate(input, editorialNote: NBATerraClient.editorialReviewNote(draft))
        } : nil)
        let decoded = (try? Data(contentsOf: location)).flatMap { try? JSONDecoder().decode(Ledger.self, from: $0) }
        self.ledger = decoded ?? Ledger()
        self.ledgerReadable = decoded != nil || !FileManager.default.fileExists(atPath: location.path)
        for key in self.ledger.reviewOperations?.keys.map({ $0 }) ?? [] where self.ledger.reviewOperations?[key]?.state == "running" {
            self.ledger.reviewOperations?[key]?.state = "uncertain"
        }
        // A persisted in-flight reservation has uncertain server outcome. Never
        // resubmit automatically after an app crash/relaunch.
        for key in self.ledger.jobs.keys where ["running", "reviewing"].contains(self.ledger.jobs[key]?.state ?? "") {
            self.ledger.jobs[key]?.state = "uncertain"
            self.ledger.jobs[key]?.message = "上次请求结果未确认，未自动重试。"
        }
    }
    func snapshot() -> Ledger {
        updateDay(clock()); return ledger
    }
    private func updateDay(_ now: Date) {
        if ledger.dailySpendUSD == nil {
            ledger.dailySpendUSD = ledger.day.isEmpty ? [:] : [ledger.day: ledger.spentUSD]
        }
        let day = calendarDay(now)
        ledger.day = day
        ledger.spentUSD = ledger.dailySpendUSD?[day] ?? 0
        // The development-only round approval never limits formal operation.
        ledger.approvedRoundLimitUSD = nil
    }
    private func charge(_ amount: Double, day: String) {
        let revised = max(0, (ledger.dailySpendUSD?[day] ?? 0) + amount)
        ledger.dailySpendUSD?[day] = revised
        if ledger.day == day { ledger.spentUSD = revised }
    }
    /// All live manual and automatic generations enter this one serial queue.
    /// NBATerraRecapStore coalesces callers and caches before reaching it.
    func budgetedGenerate(_ input: NBARecapInput, title: String? = nil, editorialNote: String? = nil) async throws -> NBARecap {
        let key = input.cacheKey
        let operation: (UUID, Task<NBARecap, Error>)
        if let pending = paidTasks[key] { operation = pending }
        else {
            let predecessor = paidTail
            let task = Task {
                if let predecessor { _ = await predecessor.result }
                try Task.checkCancellation()
                return try await self.performPaid(input, title: title, editorialNote: editorialNote)
            }
            operation = (UUID(), task); paidTasks[key] = operation; paidTail = task
        }
        return try await withTaskCancellationHandler {
            defer { if paidTasks[key]?.0 == operation.0 { paidTasks[key] = nil } }
            return try await operation.1.value
        } onCancel: { operation.1.cancel() }
    }
    private func performPaid(_ input: NBARecapInput, title: String?, editorialNote: String?) async throws -> NBARecap {
        await lockNetwork(); defer { unlockNetwork() }
        try Task.checkCancellation()
        guard ledgerReadable else { throw NBARecapError.budgetUnavailable }
        updateDay(clock())
        let key = input.facts.gameID + "-" + input.facts.kind.rawValue
        let old = ledger.jobs[key]
        let label = title ?? input.facts.teams.map(\.name).joined(separator: " · ")
        let needsEditor = input.facts.kind == .recap && editorialNote == nil && edit != nil
        var job = Job(gameID: input.facts.gameID, title: label, kind: input.facts.kind,
            fingerprint: input.cacheKey, state: "running", message: "正在核对初稿输入", attempts: old?.attempts ?? 0,
            date: clock(), estimatedUSD: old?.estimatedUSD ?? 0, requestID: nil)
        job.editorialVersion = NBATerraClient.promptVersion(for: input.facts.kind)
        job.wordingRepairAttempted = editorialNote != nil || old?.wordingRepairAttempted == true
        job.editorialRequired = needsEditor; job.completedPasses = 0
        job.generationRequests = old?.generationRequests ?? 0
        job.usageKnown = (old?.estimatedUSD ?? 0) == 0 || old?.usageKnown == true
        ledger.jobs[key] = job
        do {
            var article = try await articlePass(input, key: key, draft: nil, editorialNote: editorialNote,
                                                model: NBATerraClient.model, suffix: needsEditor ? "-draft" : "")
            ledger.jobs[key]?.completedPasses = 1
            if needsEditor {
                // The first result is a paid draft, never a completed article.
                // Persist its settled cost before the editor can send anything.
                let draftCost = ledger.jobs[key]?.passEstimatedUSD
                ledger.jobs[key]?.state = "reviewing"; ledger.jobs[key]?.message = "正在复核赛况与文稿"
                ledger.jobs[key]?.draftRequestID = article.requestID
                ledger.jobs[key]?.draftEstimatedUSD = draftCost
                ledger.jobs[key]?.draftUsageKnown = article.estimatedUSD != nil
                try persist()
                let draft = article
                article = try await articlePass(input, key: key, draft: draft,
                    editorialNote: NBATerraClient.editorialReviewNote(draft), model: NBATerraClient.editorialModel, suffix: "")
                article.editorialPasses = 2; article.draftRequestID = draft.requestID
                article.draftEstimatedUSD = ledger.jobs[key]?.draftEstimatedUSD
                ledger.jobs[key]?.completedPasses = 2
            } else { article.editorialPasses = 1 }
            ledger.jobs[key]?.state = "done"; ledger.jobs[key]?.message = "已缓存"
            ledger.jobs[key]?.date = clock(); ledger.jobs[key]?.requestID = article.requestID
            try persist()
            return article
        } catch {
            // A draft whose editor was blocked or failed is not retried by the
            // automatic scanner, including after a new day or app restart.
            let completedPasses = ledger.jobs[key]?.completedPasses ?? 0
            let initialBudgetBlock = (error as? NBARecapError) == .dailyBudget && completedPasses == 0
            ledger.jobs[key]?.state = initialBudgetBlock ? "budget" : "failed"
            ledger.jobs[key]?.message = completedPasses > 0
                ? "初稿已完成，终审未完成：" + sanitized(error) : sanitized(error)
            if (error as? NBARecapError) == .dailyBudget { ledger.jobs[key]?.budgetLimitUSD = Self.dailyLimitUSD }
            save(); throw error
        }
    }
    /// Each pass counts, durably reserves and settles independently on its
    /// dispatch day. The outer queue keeps both passes serial with Q&A traffic.
    private func articlePass(_ input: NBARecapInput, key: String, draft: NBARecap?, editorialNote: String?,
                             model: String, suffix: String) async throws -> NBARecap {
        try Task.checkCancellation(); updateDay(clock())
        guard ledger.spentUSD < Self.dailyLimitUSD else { throw NBARecapError.dailyBudget }
        ledger.tokenCountRequests = (ledger.tokenCountRequests ?? 0) + 1
        try persist()
        let tokens: Int
        if let draft { tokens = try await editCount(input, draft) }
        else if let editorialNote {
            tokens = try await NBATerraClient(authorized: true, requestModel: model).inputTokenCount(input, editorialNote: editorialNote)
        } else { tokens = try await count(input) }
        try Task.checkCancellation(); updateDay(clock())
        let day = ledger.day, startedAt = clock()
        let cap = Self.outputLimit(inputTokens: tokens, remainingUSD: Self.dailyLimitUSD - ledger.spentUSD,
                                   maximum: NBATerraClient.maxOutputTokens(for: input.facts.kind), model: model)
        let reserve = Self.reserveUSD(inputTokens: tokens, outputTokens: cap, model: model)
        guard cap >= 300, ledger.spentUSD + reserve <= Self.dailyLimitUSD else { throw NBARecapError.dailyBudget }
        let previousJob = ledger.jobs[key]
        let previousCost = previousJob?.estimatedUSD ?? 0
        charge(reserve, day: day)
        ledger.jobs[key]?.state = draft == nil ? "running" : "reviewing"
        ledger.jobs[key]?.message = draft == nil ? "正在撰写赛后初稿" : "正在复核赛况与文稿"
        if draft == nil { ledger.jobs[key]?.attempts += 1 }
        let generationRequests = (ledger.jobs[key]?.generationRequests ?? 0) + 1
        ledger.jobs[key]?.generationRequests = generationRequests
        ledger.jobs[key]?.date = startedAt; ledger.jobs[key]?.estimatedUSD = previousCost + reserve
        ledger.jobs[key]?.requestDay = day; ledger.jobs[key]?.passStartedAt = startedAt
        ledger.jobs[key]?.passReservedUSD = reserve; ledger.jobs[key]?.passEstimatedUSD = reserve
        ledger.jobs[key]?.passModel = model
        do { try persist() } catch {
            charge(-reserve, day: day); ledger.jobs[key] = previousJob
            throw NBARecapError.budgetUnavailable
        }
        var settled = false
        do {
            let article: NBARecap
            if let draft, let edit { article = try await edit(input, draft, cap) }
            else if let editorialNote {
                let client = NBATerraClient(authorized: true, observe: { data, response in
                    NBATerraClient.savePublicEvidence(data, response: response, input: input,
                        directory: NBATerraRecapStore.evidenceDirectory, suffix: suffix)
                }, outputLimit: cap, requestModel: model)
                article = try await client.generate(input, editorialNote: editorialNote)
            } else { article = try await generate(input, cap) }
            let actual = article.estimatedUSD ?? reserve
            let usageKnown = (ledger.jobs[key]?.usageKnown ?? true) && article.estimatedUSD != nil
            charge(actual - reserve, day: day); settled = true
            ledger.jobs[key]?.estimatedUSD = previousCost + actual
            ledger.jobs[key]?.passEstimatedUSD = actual
            ledger.jobs[key]?.usageKnown = usageKnown
            ledger.jobs[key]?.requestID = article.requestID
            try persist()
            return article
        } catch {
            if !settled,
               let actual = NBATerraClient.observedCost(input, directory: NBATerraRecapStore.evidenceDirectory, suffix: suffix),
               let attributes = try? FileManager.default.attributesOfItem(atPath: NBATerraRecapStore.evidenceDirectory.appendingPathComponent(input.cacheKey + suffix + ".json").path),
               let modified = attributes[.modificationDate] as? Date, modified >= startedAt {
                charge(actual - reserve, day: day)
                ledger.jobs[key]?.estimatedUSD = previousCost + actual
                ledger.jobs[key]?.passEstimatedUSD = actual
                ledger.jobs[key]?.usageKnown = previousJob?.usageKnown ?? true
            } else if !settled { ledger.jobs[key]?.usageKnown = false }
            save(); throw error
        }
    }
    private func lockNetwork() async {
        if networkBusy { await withCheckedContinuation { networkWaiters.append($0) } }
        else { networkBusy = true }
    }
    private func unlockNetwork() {
        if networkWaiters.isEmpty { networkBusy = false }
        else { networkWaiters.removeFirst().resume() }
    }
    /// Research, conversation, automatic articles and manual articles all charge
    /// this ledger. Search reserves prompt + hosted-search context + hard tool cap.
    func reviewAnswer(gameID: String, key: String, body: Data, search: Bool,
                      client: NBAReviewQuestionClient = .init()) async throws -> NBAReviewAnswer {
        try NBAReviewQuestionClient.validateRequest(body, search: search)
        await lockNetwork(); defer { unlockNetwork() }
        try Task.checkCancellation()
        guard ledgerReadable else { throw NBARecapError.budgetUnavailable }
        updateDay(clock())
        let minimumSearchReserve = Self.reserveUSD(inputTokens: (NBAReviewQuestionClient.searchInputCeiling + 1) * (NBAReviewQuestionClient.maxSearchCalls + 1), outputTokens: NBAReviewQuestionClient.maxOutput)
            + Double(NBAReviewQuestionClient.maxSearchCalls) * 0.01
        guard ledger.spentUSD < Self.dailyLimitUSD, !search || ledger.spentUSD + minimumSearchReserve <= Self.dailyLimitUSD else { throw NBARecapError.dailyBudget }
        ledger.tokenCountRequests = (ledger.tokenCountRequests ?? 0) + 1; try persist()
        let tokens = try await client.inputCount(body)
        try Task.checkCancellation(); updateDay(clock())
        let inputCeiling = search ? (tokens + NBAReviewQuestionClient.searchInputCeiling) * (NBAReviewQuestionClient.maxSearchCalls + 1) : tokens
        let reserve = Self.reserveUSD(inputTokens: inputCeiling, outputTokens: NBAReviewQuestionClient.maxOutput)
            + (search ? Double(NBAReviewQuestionClient.maxSearchCalls) * 0.01 : 0)
        guard ledger.spentUSD + reserve <= Self.dailyLimitUSD else { throw NBARecapError.dailyBudget }
        let day = ledger.day, startedAt = clock(), operationID = UUID().uuidString
        if ledger.reviewOperations == nil { ledger.reviewOperations = [:] }
        charge(reserve, day: day)
        ledger.reviewOperations?[operationID] = ReviewOperation(gameID: gameID, day: day, startedAt: startedAt,
            state: "running", reservedUSD: reserve, actualUSD: nil, requestID: nil, usage: nil)
        do { try persist() } catch { charge(-reserve, day: day); ledger.reviewOperations?[operationID] = nil; throw NBARecapError.budgetUnavailable }
        do {
            let answer = try await client.generate(gameID: gameID, key: key, body: body, search: search)
            let actual = answer.usage?.usd
            if let actual { charge(actual - reserve, day: day) }
            ledger.reviewOperations?[operationID]?.state = "done"
            ledger.reviewOperations?[operationID]?.actualUSD = actual
            ledger.reviewOperations?[operationID]?.requestID = answer.requestID
            ledger.reviewOperations?[operationID]?.usage = answer.usage; save()
            return answer
        } catch {
            if let actual = NBAReviewQuestionClient.recordedCost(key: key, since: startedAt, directory: client.receiptDirectory) {
                charge(actual - reserve, day: day); ledger.reviewOperations?[operationID]?.actualUSD = actual
            }
            ledger.reviewOperations?[operationID]?.state = "failed"; save()
            throw error
        }
    }
    /// Revalidate a saved public return after a validator repair. No network,
    /// generation, token-count request or credential access occurs here.
    func recoverRecordedResponse(gameID: String, kind: NBARecapInput.Kind) async throws {
        let key = gameID + "-" + kind.rawValue
        guard let old = ledger.jobs[key], old.state == "failed",
              let entry = await boxes.cached(gameID: gameID) else { throw NBARecapError.invalidData }
        if old.editorialRequired == true {
            // A paid first pass or an editor that never dispatched cannot be
            // promoted by reading a stale final receipt from an earlier run.
            guard old.completedPasses == 1, old.passModel == NBATerraClient.editorialModel,
                  old.passStartedAt != nil else { throw NBARecapError.invalidData }
        }
        let input = try NBARecapInput.makeArticle(data: entry.data, gameID: gameID, dataAsOf: entry.date)
        guard input.cacheKey == old.fingerprint else { throw NBARecapError.invalidData }
        let file = NBATerraRecapStore.evidenceDirectory.appendingPathComponent(input.cacheKey + ".json")
        let data = try Data(contentsOf: file)
        let date = (try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? old.date
        guard date >= (old.passStartedAt ?? old.date) else { throw NBARecapError.invalidData }
        var article = try NBATerraClient.parse(data, input: input, now: date, allowLegacy: false,
                                             expectedModel: old.passModel ?? NBATerraClient.model)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        article.requestID = root?["requestID"] as? String
        if old.editorialRequired == true {
            article.editorialPasses = 2; article.draftRequestID = old.draftRequestID
            article.draftEstimatedUSD = old.draftEstimatedUSD
        } else { article.editorialPasses = 1 }
        await articles.insertValidated(article)
        let previousPassCost = old.passEstimatedUSD ?? old.estimatedUSD
        let actual = article.estimatedUSD ?? previousPassCost
        updateDay(clock()); charge(actual - previousPassCost, day: old.requestDay ?? calendarDay(old.date))
        ledger.jobs[key]?.state = "done"; ledger.jobs[key]?.message = "已缓存"
        ledger.jobs[key]?.estimatedUSD = old.estimatedUSD + actual - previousPassCost
        ledger.jobs[key]?.passEstimatedUSD = actual
        ledger.jobs[key]?.usageKnown = old.editorialRequired != true || old.draftUsageKnown == true
        ledger.jobs[key]?.completedPasses = old.editorialRequired == true ? 2 : 1
        ledger.jobs[key]?.requestID = article.requestID; save()
    }
    /// One evidenced wording correction, only from the explicit review runner.
    func repairWording(gameID: String, note: String) async throws {
        let key = gameID + "-recap"
        guard let old = ledger.jobs[key], old.state == "failed", old.wordingRepairAttempted != true,
              let entry = await boxes.cached(gameID: gameID) else { throw NBARecapError.authorizationRequired }
        let input = try NBARecapInput.makeArticle(data: entry.data, gameID: gameID, dataAsOf: entry.date)
        let article = try await budgetedGenerate(input, title: old.title, editorialNote: note)
        await articles.insertValidated(article)
    }
    func cancel() async {
        worker?.cancel()
        if let activeInput { await articles.cancel(activeInput) }
    }
    func observe(now: Date = Date()) {
        guard enabled(), !processing, worker == nil, now >= nextScan else { return }
        nextScan = now.addingTimeInterval(300)
        worker = Task {
            let calendar = NBASchedulePolicy.calendar
            let today = calendar.startOfDay(for: now)
            let next = calendar.date(byAdding: .day, value: 1, to: today)!
            if let schedule = try? await NBAScheduleStore.shared.load(day: today, extraDays: [next]), !schedule.refreshFailed {
                await process(events: Self.candidates(schedule.games, now: now), now: now)
            }
            worker = nil
        }
    }
    static func candidates(_ events: [Event], now: Date) -> [Event] {
        let calendar = NBASchedulePolicy.calendar
        let today = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: today)!
        let nextEnd = calendar.date(byAdding: .day, value: 1, to: end)!
        var seen: Set<String> = []
        return events.filter { event in
            guard seen.insert(event.id).inserted, let date = NBASchedulePolicy.startDate(event.date) else { return false }
            if event.status.type.state == "post", event.status.type.completed { return date >= today && date < end }
            return event.status.type.state == "pre" && !event.status.type.completed && date > now && date >= end && date < nextEnd
        }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }
    func process(events: [Event], now: Date = Date(), seedUSD: Double = 0, resumeBudget: Bool = false,
                 editorialUpgrade: Bool = false, approvedRoundLimitUSD: Double? = nil) async {
        guard ledgerReadable, !processing, enabled() else { return }
        processing = true; defer { processing = false }
        updateDay(now)
        if !ledger.seeded, seedUSD > 0 { charge(seedUSD, day: ledger.day); ledger.seeded = true }
        save()
        for event in events.prefix(40) {
            guard enabled(), !Task.isCancelled else { return }
            let kind: NBARecapInput.Kind = event.status.type.state == "post" ? .recap : .pregame
            let editorialVersion = NBATerraClient.promptVersion(for: kind)
            let title = (NBASchedulePolicy.startDate(event.date).map { NBASchedulePolicy.startTime($0, includeDay: true) + " · " } ?? "") + NBAMenuPresentation.title(for: event)
            let key = event.id + "-" + kind.rawValue
            let old = ledger.jobs[key]
            do {
                let entry = try await boxes.load(gameID: event.id, force: old?.state != "done")
                guard enabled(), !Task.isCancelled else { return }
                guard !entry.refreshFailed else { throw URLError(.cannotLoadFromNetwork) }
                let input = try NBARecapInput.makeArticle(data: entry.data, gameID: event.id, dataAsOf: entry.date, now: now)
                guard input.facts.kind == kind else { continue }
                if let saved = await articles.cached(input, allowLegacy: !editorialUpgrade) {
                    var cachedJob = old ?? Job(gameID: event.id, title: title, kind: kind, fingerprint: saved.cacheKey,
                        state: "done", message: "已缓存", attempts: 1, date: clock(), estimatedUSD: 0, requestID: saved.requestID)
                    cachedJob.title = title; cachedJob.fingerprint = saved.cacheKey
                    cachedJob.state = "done"; cachedJob.message = saved.isLegacy ? "已缓存 · 旧版文案" : "已缓存"
                    cachedJob.requestID = saved.requestID
                    if old == nil {
                        cachedJob.usageKnown = saved.inputTokens != nil && saved.outputTokens != nil
                        cachedJob.completedPasses = saved.editorialPasses
                        cachedJob.draftRequestID = saved.draftRequestID; cachedJob.draftEstimatedUSD = saved.draftEstimatedUSD
                    }
                    ledger.jobs[key] = cachedJob
                    save(); continue
                }
                if editorialUpgrade, old?.editorialVersion == editorialVersion { continue }
                if !editorialUpgrade, let old, ["failed", "uncertain", "running", "reviewing"].contains(old.state) {
                    ledger.jobs[key]?.title = title; save(); continue
                }
                if !resumeBudget, old?.state == "budget", old?.budgetLimitUSD == Self.dailyLimitUSD,
                   old.map({ calendarDay($0.date) }) == ledger.day { continue }
                if kind == .recap {
                    let scoreboard = (event.competitions.first?.competitors ?? []).reduce(into: [String: Int]()) { result, side in
                        if let score = side.score.flatMap(Int.init) { result[side.team?.id ?? side.id] = score }
                    }
                    guard input.facts.teams.allSatisfy({ !$0.statistics.isEmpty && !$0.players.isEmpty && scoreboard[$0.id] == $0.score }) else { throw NBARecapError.invalidData }
                }
                if !editorialUpgrade, let old, old.state != "budget", old.attempts > 0 {
                    // At most one bounded pregame refresh, after 30 minutes.
                    guard kind == .pregame, old.attempts < 2, Date().timeIntervalSince(old.date) >= 1800 else {
                        ledger.jobs[key]?.state = "stale"; ledger.jobs[key]?.message = "关键事实有更新，可手动刷新生成。"; save(); continue
                    }
                }
                guard enabled(), !Task.isCancelled else { return }
                activeInput = input
                do {
                    _ = try await articles.load(input, generateOverride: { input in
                        try await self.budgetedGenerate(input, title: title)
                    })
                } catch {
                    // The shared generation path persisted failure or budget state.
                    if (error as? NBARecapError) != .dailyBudget, ledger.jobs[key]?.state != "failed" {
                        var failed = ledger.jobs[key] ?? Job(gameID: event.id, title: title, kind: kind, fingerprint: input.cacheKey,
                            state: "failed", message: sanitized(error), attempts: old?.attempts ?? 0,
                            date: clock(), estimatedUSD: old?.estimatedUSD ?? 0, requestID: nil)
                        failed.state = "failed"; failed.message = sanitized(error); ledger.jobs[key] = failed
                        save()
                    }
                }
                activeInput = nil
            } catch {
                let waiting = (error as? NBARecapError).map { [.notFinal, .notPregame, .invalidData].contains($0) } ?? false
                var failed = ledger.jobs[key] ?? Job(gameID: event.id, title: title, kind: kind, fingerprint: old?.fingerprint ?? "",
                    state: waiting ? "waiting" : "failed", message: sanitized(error), attempts: old?.attempts ?? 0,
                    date: clock(), estimatedUSD: old?.estimatedUSD ?? 0, requestID: nil)
                failed.title = title; failed.state = waiting ? "waiting" : "failed"; failed.message = sanitized(error)
                failed.editorialVersion = editorialUpgrade ? editorialVersion : old?.editorialVersion
                ledger.jobs[key] = failed
                save()
            }
        }
    }
    static func reserveUSD(inputTokens: Int, outputTokens: Int = NBATerraClient.maxOutputTokens,
                           model: String = NBATerraClient.model) -> Double {
        // All input at the higher cache-write rate, all output at its hard cap.
        let rate = NBATerraClient.pricing(for: model)
        return (Double(inputTokens) * rate.written + Double(outputTokens) * rate.output) / 1_000_000
    }
    static func outputLimit(inputTokens: Int, remainingUSD: Double, maximum: Int = NBATerraClient.maxOutputTokens,
                            model: String = NBATerraClient.model) -> Int {
        let rate = NBATerraClient.pricing(for: model)
        return max(0, min(maximum, Int(floor((remainingUSD - Double(inputTokens) * rate.written / 1_000_000) * 1_000_000 / rate.output)) - 1))
    }
    private func calendarDay(_ date: Date) -> String { NBAHistoryStore.dayKey(date, calendar: NBASchedulePolicy.calendar) }
    private func save() {
        try? persist()
    }
    private func persist() throws {
        guard ledgerReadable else { throw NBARecapError.budgetUnavailable }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ledger).write(to: file, options: .atomic)
    }
    private func sanitized(_ error: Error) -> String {
        if error is NBARecapError || error is NBAOpenAICredential.Failure || error is NBAOpenAIPrivateConfiguration.Failure { return error.localizedDescription }
        return "准备失败，未自动重试；可打开本场解读手动重试。"
    }
}
