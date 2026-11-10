import Foundation

/// A bounded two-pass workflow. Terra chooses local queries, the app computes
/// them, then Terra answers with at most one hosted official search. Every
/// model pass reserves and reconciles the same persistent daily ledger.
struct NBAReviewResearch: Sendable {
    enum Failure: Error, LocalizedError {
        case budgetAfterQuery
        var errorDescription: String? { "本场查数已完成；本日剩余额度不足以安全预留后续解读／资料查证。没有自动重试，已发生用量仍计入每日 $\(NBATerraAutofill.dailyLimitText) 上限。" }
    }
    let budget: NBATerraAutofill
    let client: NBAReviewQuestionClient
    let auditDirectory: URL?
    init(budget: NBATerraAutofill = .shared, client: NBAReviewQuestionClient = .init(), auditDirectory: URL? = nil) { self.budget = budget;self.client = client;self.auditDirectory = auditDirectory }
    func answer(evidence: NBAReviewEvidence, segmentID: String?, pointID: String?, question: String, turns: [NBAReviewTurn], boxes: NBABoxScoreStore) async throws -> NBAReviewAnswer {
        let key = NBAReviewQuestionClient.key(evidence:evidence,segmentID:segmentID,question:question,turns:turns,pointID:pointID)
        let body = try NBAReviewQuestionClient.queryBody(evidence:evidence,segmentID:segmentID,pointID:pointID,question:question,turns:turns)
        let plan = try await budget.reviewAnswer(gameID:evidence.gameID,key:key + "-query",body:body,search:false,client:client)
        try Task.checkCancellation()
        guard let calls = plan.toolCalls,calls.count == 1,let call = calls.first else { throw NBARecapError.invalidResponse }
        let request = try NBAReviewGameQuery.decode(call.arguments)
        let unknownNames = request.queries.compactMap(\.player).filter { name in !evidence.athletes.contains { NBAReviewGameQuery.matches(name,athlete:$0) } }
        let identities = AppRuntime.suppressesLiveWork ? [] : await NBAReviewIdentityDirectory.shared.lookup(unknownNames)
        let historyPlayers = Set(request.queries.filter { $0.kind == .recent }.compactMap(\.player).flatMap { name in evidence.athletes.filter { NBAReviewGameQuery.matches(name,athlete:$0) }.map(\.id) })
        let recentRoles = AppRuntime.suppressesLiveWork ? [] : await NBAReviewPlayerHistory.shared.lookup(playerIDs:historyPlayers)
        let selection = evidence.segments.first { $0.id == segmentID }
        var result = try NBAReviewGameQuery.execute(request,evidence:evidence,segmentID:segmentID,frozenSelection:selection,identities:identities,recentRoles:recentRoles)
        if result.missingEvents,let refreshed = await NBAReviewEvidenceRefresh.shared.supplement(evidence,boxes:boxes) {
            result = try NBAReviewGameQuery.execute(request,evidence:refreshed,segmentID:segmentID,frozenSelection:selection,identities:identities,recentRoles:recentRoles)
        }
        try Task.checkCancellation()
        if let auditDirectory {
            let audit: [String:Any] = ["gameID":evidence.gameID,"queryRequestID":plan.requestID ?? "未提供","tool":"query_game_facts","arguments":try JSONSerialization.jsonObject(with:Data(call.arguments.utf8)),"result":try JSONSerialization.jsonObject(with:Data(result.json.utf8))]
            try? FileManager.default.createDirectory(at:auditDirectory,withIntermediateDirectories:true)
            if let data = try? JSONSerialization.data(withJSONObject:audit,options:[.sortedKeys]) { try? data.write(to:auditDirectory.appendingPathComponent(key + ".json"),options:.atomic) }
        }
        func generate(_ suffix: String, search: Bool, phase: NBAReviewQuestionClient.AnswerPhase) async throws -> NBAReviewAnswer {
            let body = try NBAReviewQuestionClient.answerBody(evidence:evidence,segmentID:segmentID,pointID:pointID,question:question,turns:turns,call:call,result:result,searchOverride:search,phase:phase)
            return try await budget.reviewAnswer(gameID:evidence.gameID,key:key + suffix,body:body,search:search,client:client)
        }
        var answer: NBAReviewAnswer
        do {
            if request.intent == .mixed, result.requiresOfficial {
                let local = try await generate("-analysis",search:false,phase:.localAnalysis)
                try NBAReviewQuestionClient.validateLocal(local,evidence:evidence,segmentID:segmentID,pointID:pointID,extraNumbers:result.numbers,extraEntityNames:result.entityNames)
                try Task.checkCancellation()
                do { answer = Self.combine(local:local,external:try await generate("-external",search:true,phase:.external),warning:nil) }
                catch {
                    if Task.isCancelled { throw error }
                    answer = Self.combine(local:local,external:nil,warning:"补充外部查证未完成，以上判断仍依据本场数据。未自动重试，已发送请求的未知费用继续预留。")
                }
            } else { answer = try await generate("-answer",search:result.requiresOfficial,phase:.normal) }
        }
        catch NBARecapError.dailyBudget { throw Failure.budgetAfterQuery }
        try Task.checkCancellation()
        guard answer.toolCalls?.isEmpty != false,!answer.text.isEmpty else { throw NBARecapError.invalidResponse }
        try NBAReviewQuestionClient.validateLocal(answer,evidence:evidence,segmentID:segmentID,pointID:pointID,extraNumbers:result.numbers,extraEntityNames:result.entityNames)
        answer.localEvidence = result.evidence;answer.queryRequestID = plan.requestID
        answer.policyVersion = NBAReviewQuestionClient.version
        answer.requestIDs = ([plan.requestID] + (answer.requestIDs?.map(Optional.some) ?? [answer.requestID])).compactMap { $0 }
        return answer
    }
    static func combine(local: NBAReviewAnswer, external: NBAReviewAnswer?, warning: String?) -> NBAReviewAnswer {
        let usable = external.map { !$0.isEvidenceNotice && !$0.sources.isEmpty } ?? false
        let offset = local.text.count + 2
        let text = usable ? local.text + "\n\n" + external!.text : local.text
        let citations = local.citations + (usable ? external!.citations.map { .init(start:$0.start+offset,end:$0.end+offset,url:$0.url) } : [])
        let total: NBAReviewUsage? = local.usage.map { a in
            let b = external?.usage
            return .init(input:a.input+(b?.input ?? 0),output:a.output+(b?.output ?? 0),cached:a.cached+(b?.cached ?? 0),written:a.written+(b?.written ?? 0),searches:a.searches+(b?.searches ?? 0))
        }
        var answer = NBAReviewAnswer(gameID:local.gameID,text:text,sources:usable ? external!.sources : local.sources,citations:citations,generatedAt:external?.generatedAt ?? local.generatedAt,requestID:external?.requestID ?? local.requestID,responseID:external?.responseID ?? local.responseID,usage:total,searched:true)
        answer.searchWarning = usable ? nil : warning ?? "外部补充暂未取得可引用资料；本场数据分析已保留。"
        answer.requestIDs = [local.requestID,external?.requestID].compactMap { $0 }
        return answer
    }
}
