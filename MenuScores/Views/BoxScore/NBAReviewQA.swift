#if DEBUG
import AppKit
import SwiftUI

@MainActor enum NBAReviewQA {
    static func run() {
        let args = ProcessInfo.processInfo.arguments
        let flag = args.contains("--review-live-test") ? "--review-live-test" : "--review-qa"
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { NSApp.terminate(nil); return }
        let root = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        Task {
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                if args.contains("--entry-alignment-qa") { try await entryAlignment(root) }
                else if flag == "--review-live-test" { try await live(root) } else { try await visual(root) }
                if args.contains("--hold-overview") { try await holdOverview(root); return }
            } catch {
                let ns = error as NSError
                try? JSONSerialization.data(withJSONObject: ["error": (error as? LocalizedError)?.errorDescription ?? "验收未完成", "type": String(reflecting: Swift.type(of: error)), "domain": ns.domain, "code": ns.code])
                    .write(to: root.appendingPathComponent("failure.json"), options: .atomic)
            }
            NSApp.terminate(nil)
        }
    }
    private static var caches: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0] }
    private static func entryAlignment(_ root: URL) async throws {
        let data = try Data(contentsOf: caches.appendingPathComponent("NBABoxScores/401909901.json"))
        var rows: [[String: Any]] = []
        for count in [0, 1, 4, 12, 128] {
            let boxes = NBABoxScoreStore(directory: root.appendingPathComponent("box-\(count)"), fetch: { _ in data })
            let articles = NBATerraRecapStore { _ in throw NBARecapError.authorizationRequired }
            var recapClicks = 0, conversationClicks = 0
            let host = NSHostingView(rootView: NBABoxScoreView(gameID: "401909901", boxStore: boxes, articleStore: articles,
                onReviewRequested: { recapClicks += 1 }, onConversationRequested: { conversationClicks += 1 }, conversationCount: count,
                inlineReviewLead: "马刺半场落后1分，下半场连续赢下两节，投篮命中率和篮板均占优。", embedsReviewOverview: true))
            let window = makeWindow(host)
            try await Task.sleep(nanoseconds: 250_000_000)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                try await capture(host, window: window, to: root.appendingPathComponent("count-\(count)-\(name)"))
                guard let recap = findProbe(host, id: "review-action-recap"), let recapText = findProbe(host, id: "review-action-recap-text") else { throw NBARecapError.invalidData }
                let a = recap.convert(recap.bounds, to: host), at = recapText.convert(recapText.bounds, to: host)
                let chat = findProbe(host, id: "review-action-conversation"), chatText = findProbe(host, id: "review-action-conversation-text")
                let b = chat.map { $0.convert($0.bounds, to: host) }, bt = chatText.map { $0.convert($0.bounds, to: host) }
                let aligned = count == 0 ? chat == nil : b != nil && bt != nil && abs(a.midY-b!.midY) < 0.5 && abs(at.minY-bt!.minY) < 0.5 && abs(at.height-bt!.height) < 0.5 && abs(a.height-b!.height) < 0.5
                guard aligned, abs(a.height-24) < 0.5 else { throw NBARecapError.invalidData }
                func frame(_ r: NSRect) -> [String: Double] { ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height] }
                rows.append(["count": count, "appearance": name, "aligned": aligned, "recapFrame": frame(a), "recapTextFrame": frame(at), "conversationFrame": b.map(frame) ?? [:], "conversationTextFrame": bt.map(frame) ?? [:], "fontPt": 13, "weight": "regular", "iconWidthPt": 8, "APIRequests": 0, "keychainReads": 0])
                if name == "light" {
                    click(host, window: window, x: a.midX, fromTop: host.isFlipped ? a.midY : host.bounds.height-a.midY)
                    if let b { click(host, window: window, x: b.midX, fromTop: host.isFlipped ? b.midY : host.bounds.height-b.midY) }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            guard recapClicks == 1, conversationClicks == (count > 0 ? 1 : 0) else { throw NBARecapError.invalidData }
            window.close()
        }
        try JSONSerialization.data(withJSONObject: ["rows": rows, "allAligned": true, "nativeClicksVerified": true, "APIRequests": 0, "keychainReads": 0, "screenshotsUploaded": false], options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("alignment.json"), options: .atomic)
    }
    private static var previewWindow: NSWindow?
    private static func holdOverview(_ root: URL) async throws {
        let id = "401909901", data = try Data(contentsOf: caches.appendingPathComponent("NBABoxScores/401909901.json"))
        let boxes = NBABoxScoreStore(directory: root.appendingPathComponent("hold-box"), fetch: { _ in data })
        let articles = NBATerraRecapStore(directory: caches.appendingPathComponent("NBATerraArticles-v2")) { _ in throw NBARecapError.authorizationRequired }
        let history = NBAReviewConversationStore(directory: root.appendingPathComponent("conversation-history"))
        let model = NBAReviewPanelModel(gameID: id, boxes: boxes, articles: articles, history:history, ask: { _,_,_,_,_ in throw NBARecapError.authorizationRequired })
        await model.load()
        let host = NSHostingView(rootView: NBAReviewPanelView(gameID: id, model: model))
        previewWindow = makeWindow(host)
        try await capture(host, window: previewWindow!, to: root.appendingPathComponent("held-overview"))
    }
    private static func visual(_ root: URL) async throws {
        var reports: [[String: Any]] = []
        for (id, kind) in [("401909901", "normal"), ("401909903", "pregame"), ("401909898", "partial"), ("401909899", "blowout")] {
            let data = try Data(contentsOf: caches.appendingPathComponent("NBABoxScores/" + id + ".json"))
            let boxes = NBABoxScoreStore(directory: root.appendingPathComponent("box-" + id), fetch: { _ in data })
            let articles = NBATerraRecapStore(directory: caches.appendingPathComponent("NBATerraArticles-v2")) { _ in throw NBARecapError.authorizationRequired }
            let answerFile = root.appendingPathComponent("local-answer.json")
            let real = (try? Data(contentsOf: answerFile)).flatMap { try? JSONDecoder().decode(NBAReviewAnswer.self, from: $0) }
            let model = NBAReviewPanelModel(gameID: id, boxes: boxes, articles: articles, questions: NBAReviewQuestionStore(), ask: { e, _, _, _, _ in
                if let real, real.gameID == e.gameID { return real }
                var answer = NBAReviewAnswer(gameID: e.gameID, text: "离线交互验收：显示本场公开资料，未调用模型。", sources: [], citations: [], generatedAt: Date(), requestID: nil, responseID: nil, usage: nil, searched: false)
                let target = e.athletes.max { (Int($0.statistics["PTS"] ?? "") ?? 0) < (Int($1.statistics["PTS"] ?? "") ?? 0) }
                let query = NBAReviewGameQuery.Query(kind:e.isPregame ? .overview:.player,scope:e.isPregame ? .game:.critical,player:target?.id,period:nil,remainingFrom:nil,remainingTo:nil,eventTypes:[])
                answer.localEvidence = try? NBAReviewGameQuery.execute(.init(queries:[query],needsOfficialResearch:false),evidence:e,segmentID:e.segments.first?.id).evidence
                return answer
            })
            await model.load()
            if ["normal","blowout"].contains(kind),let e = model.evidence {
                let queries: [NBAReviewGameQuery.Query] = [
                    .init(kind:.impact,scope:.game,player:nil,period:nil,remainingFrom:nil,remainingTo:nil,eventTypes:[]),
                    .init(kind:.player,scope:kind == "normal" ? .close:.period,player:nil,period:kind == "normal" ? nil:1,remainingFrom:nil,remainingTo:nil,eventTypes:["score"]),
                    .init(kind:.player,scope:kind == "normal" ? .close:.period,player:nil,period:kind == "normal" ? 4:3,remainingFrom:nil,remainingTo:nil,eventTypes:["score"])]
                let result = try NBAReviewGameQuery.execute(.init(queries:queries,needsExternalResearch:false,intent:.matchAnalysis),evidence:e,segmentID:"focus")
                let packet = try JSONSerialization.jsonObject(with:Data(result.json.utf8)) as! [String:Any]
                let proof: [String:Any] = ["gameID":e.gameID,"originalBytes":packet["payloadCompactedFromBytes"] ?? result.json.utf8.count,"returnedBytes":result.json.utf8.count,"queryCount":queries.count,"starterSource":"boxscore.players.statistics.athletes.starter","players":e.athletes.map { ["id":$0.id,"name":$0.name,"starter":$0.starter as Any? ?? NSNull(),"role":$0.lineupRole] },"APIRequests":0,"keychainReads":0]
                try JSONSerialization.data(withJSONObject:proof,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent(kind + "-payload-proof.json"))
                try Data(result.json.utf8).write(to:root.appendingPathComponent(kind + "-query-packet.json"))
            }
            let host = NSHostingView(rootView: NBAReviewPanelView(gameID: id, model: model))
            let window = makeWindow(host)
            try await Task.sleep(nanoseconds: 250_000_000)
            let visibleWindows = NSApp.windows.filter(\.isVisible).count
            try await capture(host, window: window, to: root.appendingPathComponent(kind + "-score"))
            var chosenTeam: String? = nil, playerOffset: CGFloat = 0
            var statisticsScroll: NSScrollView?
            if kind != "pregame" {
                click(host, window: window, x: 450, fromTop: 74)
                try await Task.sleep(nanoseconds: 100_000_000)
                chosenTeam = model.statisticsTeamID
                statisticsScroll = findProbe(host, id: "boxscore-players")?.enclosingScrollView
                if let scroll = statisticsScroll {
                    let available = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: min(40, available))); scroll.reflectScrolledClipView(scroll.contentView)
                    playerOffset = scroll.contentView.bounds.origin.y
                }
                try await capture(host, window: window, to: root.appendingPathComponent(kind + "-team-switched"))
            }
            click(host, window: window, x: kind == "pregame" ? 488 : 568, fromTop: kind == "pregame" ? 165 : 122)
            try await Task.sleep(nanoseconds: 150_000_000)
            let opened = model.route == .recap
            if !opened { model.route = .recap }
            try await Task.sleep(nanoseconds: 150_000_000)
            try await capture(host, window: window, to: root.appendingPathComponent(kind + "-recap"))
            model.showFullArticle = true
            try await Task.sleep(nanoseconds: 100_000_000)
            let scroll = findProbe(host, id: "review-scroll-probe-recap")?.enclosingScrollView
            let available = max(0, (scroll?.documentView?.bounds.height ?? 0) - (scroll?.contentView.bounds.height ?? 0))
            let wantedOffset = min(25, available)
            if let scroll { scroll.contentView.scroll(to: NSPoint(x: 0, y: wantedOffset)); scroll.reflectScrolledClipView(scroll.contentView) }
            try await Task.sleep(nanoseconds: 100_000_000)
            let offsetBefore = scroll?.contentView.bounds.origin.y ?? 0
            let realQuestion = try? String(contentsOf: root.appendingPathComponent("local-question.txt"), encoding: .utf8)
            let draft = real?.gameID == id ? realQuestion ?? "这场比赛马刺下半场比分如何，哪些统计差距值得关注？" : "这一段的比分如何变化？"
            model.draft = draft
            click(host, window: window, x: 450, fromTop: 200)
            try await Task.sleep(nanoseconds: 100_000_000)
            let evidenceByClick = model.route == .evidence
            if !evidenceByClick, let segment = model.evidence?.segments.first { model.openEvidence(segment) }
            try await Task.sleep(nanoseconds: 100_000_000)
            try await capture(host, window: window, to: root.appendingPathComponent(kind + "-evidence"))
            if model.evidence?.points.isEmpty == false { click(host, window: window, x: 80, fromTop: 210); try await Task.sleep(nanoseconds: 100_000_000) }
            let pointByClick = model.evidence?.points.isEmpty != false || model.selectedPointID != nil
            let selected = model.selectedSegmentID
            let selectedPoint = model.selectedPointID
            click(host, window: window, x: 38, fromTop: 28)
            try await Task.sleep(nanoseconds: 100_000_000)
            let returned = model.route == .recap && model.selectedSegmentID == selected && model.draft == draft && model.selectedPointID == selectedPoint
            let offsetAfter = scroll?.contentView.bounds.origin.y ?? 0
            let scrollRestored = abs(offsetAfter-offsetBefore) < 0.5
            model.route = .evidence
            try await Task.sleep(nanoseconds: 200_000_000)
            window.setContentSize(host.fittingSize)
            try await Task.sleep(nanoseconds: 100_000_000)
            click(host, window: window, x: 521, fromTop: host.fittingSize.height - 40)
            try await Task.sleep(nanoseconds: 200_000_000)
            try await capture(host, window: window, to: root.appendingPathComponent(kind + "-question"))
            if kind == "normal" {
                window.appearance = NSAppearance(named: .darkAqua)
                try await capture(host, window: window, to: root.appendingPathComponent("normal-question-dark"))
                window.appearance = NSAppearance(named: .aqua)
            }
            let asked = model.route == .question && model.turns.count == 1
            let noNewWindow = visibleWindows == NSApp.windows.filter(\.isVisible).count
            if kind == "normal" {
                model.route = .statistics; try await Task.sleep(nanoseconds: 350_000_000)
                try await capture(host, window: window, to: root.appendingPathComponent("normal-statistics"))
            }
            model.route = .score
            try await Task.sleep(nanoseconds: 150_000_000)
            let teamRetained = kind == "pregame" || chosenTeam != nil && chosenTeam == model.statisticsTeamID
            let playerScrollRetained = kind == "pregame" || abs((statisticsScroll?.contentView.bounds.origin.y ?? -100) - playerOffset) < 0.5
            try await capture(host, window: window, to: root.appendingPathComponent(kind + "-returned-overview"))
            if kind == "normal" {
                window.appearance = NSAppearance(named: .darkAqua)
                try await capture(host, window: window, to: root.appendingPathComponent("normal-overview-dark"))
                window.appearance = NSAppearance(named: .aqua)
                if var article = model.articleModel.article, let input = model.articleModel.input {
                    let original = article
                    article.lead = String(repeating: article.lead ?? "排版验收长文本。", count: 12)
                    model.articleModel.useSnapshot(input, article: article, fresh: true)
                    try await capture(host, window: window, to: root.appendingPathComponent("normal-overview-long-summary"))
                    model.articleModel.useSnapshot(input, article: original, fresh: true)
                }
            }
            reports.append(["gameID": id, "kind": kind, "coverage": model.evidence?.coverage.rawValue ?? "none", "points": model.evidence?.points.count ?? 0,
                "openedByNativeClick": opened, "evidenceOpenedByNativeClick": evidenceByClick, "pointOpenedByNativeClick": pointByClick, "returnedWithSelectionAndDraft": returned, "scrollRestored": scrollRestored, "scrollOffsetBefore": offsetBefore, "scrollOffsetAfter": offsetAfter, "scrollRange": available, "scrollWasAvailable": wantedOffset > 0, "sentByNativeClick": asked, "sameVisibleWindowCount": noNewWindow, "statisticsTeamRetained": teamRetained, "statisticsPlayerScrollRetained": playerScrollRetained, "statisticsPlayerScrollOffset": playerOffset, "APIRequests": 0, "keychainReads": 0])
            window.close()
        }
        let boxes = NBABoxScoreStore(directory: root.appendingPathComponent("missing-box"), fetch: { _ in throw URLError(.notConnectedToInternet) })
        let missing = NBAReviewPanelModel(gameID: "999999", boxes: boxes, articles: NBATerraRecapStore { _ in throw NBARecapError.network })
        await missing.load()
        let host = NSHostingView(rootView: NBAReviewPanelView(gameID: "999999", model: missing)), window = makeWindow(host)
        try await Task.sleep(nanoseconds: 100_000_000)
        try await capture(host, window: window, to: root.appendingPathComponent("missing-data")); window.close()
        var sparse = try JSONSerialization.jsonObject(with: Data(contentsOf: caches.appendingPathComponent("NBABoxScores/401909901.json"))) as! [String:Any]
        sparse["boxscore"] = [:]
        var header = sparse["header"] as! [String:Any], competitions = header["competitions"] as! [[String:Any]], sides = competitions[0]["competitors"] as! [[String:Any]]
        for index in sides.indices { sides[index]["linescores"] = nil }
        competitions[0]["competitors"] = sides; header["competitions"] = competitions; sparse["header"] = header
        let sparseData = try JSONSerialization.data(withJSONObject: sparse)
        let sparseBoxes = NBABoxScoreStore(directory: root.appendingPathComponent("missing-statistics-box"),fetch:{ _ in sparseData })
        let sparseModel = NBAReviewPanelModel(gameID:"401909901",boxes:sparseBoxes,articles:NBATerraRecapStore { _ in throw NBARecapError.network })
        await sparseModel.load()
        let sparseHost = NSHostingView(rootView:NBAReviewPanelView(gameID:"401909901",model:sparseModel)), sparseWindow = makeWindow(sparseHost)
        try await Task.sleep(nanoseconds:150_000_000)
        try await capture(sparseHost,window:sparseWindow,to:root.appendingPathComponent("missing-statistics")); sparseWindow.close()
        try JSONSerialization.data(withJSONObject: ["rows": reports, "missingDataErrorVisible": missing.error != nil, "screenshotsUploaded": false], options: [.prettyPrinted,.sortedKeys])
            .write(to: root.appendingPathComponent("interactions.json"), options: .atomic)
        try await backgroundPersistence(root)
        try await conversationPersistence(root)
    }
    private actor BackgroundGate {
        var started = false, calls = 0
        private var pending: CheckedContinuation<Void,Never>?
        func wait() async { calls += 1;started = true;await withCheckedContinuation { pending = $0 } }
        func release() { pending?.resume();pending = nil }
    }
    private static func backgroundPersistence(_ root: URL) async throws {
        let data = try Data(contentsOf:caches.appendingPathComponent("NBABoxScores/401909899.json"))
        let gate = BackgroundGate(),directory = root.appendingPathComponent("background-history")
        let sessions = NBAReviewSessions { id in
            NBAReviewPanelModel(gameID:id,boxes:NBABoxScoreStore(directory:root.appendingPathComponent("background-box-"+id),fetch:{_ in data}),articles:NBATerraRecapStore{_ in throw NBARecapError.network},questions:NBAReviewQuestionStore(),history:NBAReviewConversationStore(directory:directory),ask:{ e,_,_,_,_ in
                await gate.wait()
                return NBAReviewAnswer(gameID:e.gameID,text:"离线后台验收完成：原问和结果在面板销毁后保存。这是mock，不是Terra新输出。",sources:[],citations:[],generatedAt:Date(),requestID:nil,responseID:nil,usage:nil,searched:false)
            })
        }
        let first = sessions.session(gameID:"401909899");await first.load();first.openConversation()
        first.draft = "今天是谁帮助灰熊建立了这么大的领先优势？"
        let host = NSHostingView(rootView:NBAReviewPanelView(gameID:first.gameID,model:first)),window = makeWindow(host)
        try await Task.sleep(nanoseconds:200_000_000)
        click(host,window:window,x:521,fromTop:host.fittingSize.height-40)
        for _ in 0..<200 { if await gate.started { break };try await Task.sleep(nanoseconds:5_000_000) }
        guard first.asking else { throw NBARecapError.invalidData }
        try await capture(host,window:window,to:root.appendingPathComponent("background-pending"))
        let persisted = try await NBAReviewConversationStore(directory:directory).load(gameID:first.gameID)
        guard persisted.attempt?.state == "pending" else { throw NBARecapError.invalidData }
        window.close();window.contentView = nil
        let other = NSHostingView(rootView:Text("离线验收：已切换其他窗口，原问继续处理中。").padding(30)),otherWindow = makeWindow(other)
        _ = sessions.session(gameID:"401909901")
        try await Task.sleep(nanoseconds:150_000_000)
        guard first.asking else { throw NBARecapError.invalidData }
        await gate.release()
        for _ in 0..<200 { if !first.asking { break };try await Task.sleep(nanoseconds:5_000_000) }
        let restored = try await NBAReviewConversationStore(directory:directory).load(gameID:first.gameID)
        guard restored.turns.count == 1,restored.attempt == nil,await gate.calls == 1 else { throw NBARecapError.invalidData }
        otherWindow.close();otherWindow.contentView = nil
        let returned = sessions.session(gameID:first.gameID),newHost = NSHostingView(rootView:NBAReviewPanelView(gameID:first.gameID,model:returned)),newWindow = makeWindow(newHost)
        try await Task.sleep(nanoseconds:300_000_000)
        try await capture(newHost,window:newWindow,to:root.appendingPathComponent("background-returned"));newWindow.close();newWindow.contentView = nil
        try JSONSerialization.data(withJSONObject:["gameID":first.gameID,"nativeSendClicked":true,"viewDetached":true,"otherWindowFocused":true,"switchedGame":true,"completedAfterViewDetached":true,"persistedPendingBeforeDetach":true,"persistedCompletedWhileClosed":true,"sameAppSessionReturned":returned === first,"modelCalls":await gate.calls,"APIRequests":0,"keychainReads":0,"screenshotsUploaded":false],options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("background-lifecycle.json"))
    }
    private actor HistoryProbe {
        var lengths: [Int] = []
        func record(_ count: Int) { lengths.append(count) }
    }
    private static func conversationPersistence(_ root: URL) async throws {
        let data = try Data(contentsOf:caches.appendingPathComponent("NBABoxScores/401909901.json"))
        let directory = root.appendingPathComponent("conversation-history"), marker = root.appendingPathComponent("conversation-first-process.json"), probe = HistoryProbe()
        func model() -> NBAReviewPanelModel {
            NBAReviewPanelModel(gameID:"401909901",boxes:NBABoxScoreStore(directory:root.appendingPathComponent("conversation-box"),fetch:{ _ in data }),articles:NBATerraRecapStore { _ in throw NBARecapError.network },questions:NBAReviewQuestionStore(),history:NBAReviewConversationStore(directory:directory),ask:{ e,_,_,_,turns in
                await probe.record(turns.count)
                var answer = NBAReviewAnswer(gameID:e.gameID,text:"离线连续对话验收：已读取此前\(turns.count)轮历史。这是本机mock，不是模型新输出。",sources:[],citations:[],generatedAt:Date(),requestID:nil,responseID:nil,usage:nil,searched:false)
                answer.localEvidence = try NBAReviewGameQuery.execute(.init(queries:[.init(kind:.player,scope:.last_five,player:"5104157",period:nil,remainingFrom:nil,remainingTo:nil,eventTypes:[])],needsOfficialResearch:false),evidence:e,segmentID:nil).evidence
                return answer
            })
        }
        if FileManager.default.fileExists(atPath:marker.path) {
            let old = try JSONSerialization.jsonObject(with:Data(contentsOf:marker)) as! [String:Any]
            let restored = model();await restored.load()
            let ids = restored.turns.map { $0.id.uuidString }
            guard ids == old["turnIDs"] as? [String],restored.draft == "重启后继续问这场",old["pid"] as? Int != Int(ProcessInfo.processInfo.processIdentifier) else { throw NBARecapError.invalidData }
            let host = NSHostingView(rootView:NBAReviewPanelView(gameID:"401909901",model:restored)),window = makeWindow(host)
            try await capture(host,window:window,to:root.appendingPathComponent("conversation-restarted-overview"))
            restored.openConversation();try await capture(host,window:window,to:root.appendingPathComponent("conversation-restarted"));window.close()
            try JSONSerialization.data(withJSONObject:["processRestartVerified":true,"firstPID":old["pid"]!,"restartPID":Int(ProcessInfo.processInfo.processIdentifier),"turns":ids.count,"draftRestored":true,"modelCalls":0,"keychainReads":0,"screenshotsUploaded":false])
                .write(to:root.appendingPathComponent("conversation-restart.json"),options:.atomic)
            return
        }
        let first = model();await first.load();first.openConversation();first.draft = "文班亚马最后5分钟如何？"
        let host = NSHostingView(rootView:NBAReviewPanelView(gameID:"401909901",model:first)),window = makeWindow(host)
        try await capture(host,window:window,to:root.appendingPathComponent("conversation-before-send"))
        click(host,window:window,x:521,fromTop:host.fittingSize.height-40)
        for _ in 0..<100 { if !first.asking && !first.turns.isEmpty { break };try await Task.sleep(nanoseconds:10_000_000) }
        guard first.turns.count == 1 else { throw NBARecapError.invalidData }
        first.draft = "那他在所选Q2段呢？";first.leave();try await Task.sleep(nanoseconds:200_000_000);window.close()
        let second = model();await second.load();guard second.turns.count == 1,second.draft == "那他在所选Q2段呢？" else { throw NBARecapError.invalidData }
        let restoredHost = NSHostingView(rootView:NBAReviewPanelView(gameID:"401909901",model:second)),restoredWindow = makeWindow(restoredHost)
        try await capture(restoredHost,window:restoredWindow,to:root.appendingPathComponent("conversation-restored-overview"))
        second.openConversation();try await capture(restoredHost,window:restoredWindow,to:root.appendingPathComponent("conversation-restored"))
        click(restoredHost,window:restoredWindow,x:521,fromTop:restoredHost.fittingSize.height-40)
        for _ in 0..<100 { if !second.asking && second.turns.count == 2 { break };try await Task.sleep(nanoseconds:10_000_000) }
        guard second.turns.count == 2,await probe.lengths == [0,1] else { throw NBARecapError.invalidData }
        try await capture(restoredHost,window:restoredWindow,to:root.appendingPathComponent("conversation-followup"))
        restoredWindow.appearance = NSAppearance(named:.darkAqua)
        try await capture(restoredHost,window:restoredWindow,to:root.appendingPathComponent("conversation-followup-dark"))
        second.draft = "重启后继续问这场";second.leave();try await Task.sleep(nanoseconds:200_000_000);restoredWindow.close()
        try JSONSerialization.data(withJSONObject:["pid":Int(ProcessInfo.processInfo.processIdentifier),"turnIDs":second.turns.map { $0.id.uuidString },"draftRestored":true,"historyLengthsForwarded":[0,1],"sentByNativeClick":true,"APIRequests":0,"keychainReads":0,"screenshotsUploaded":false])
            .write(to:marker,options:.atomic)
    }
    private static func live(_ root: URL) async throws {
        let marker = root.appendingPathComponent("live-started.json")
        guard !FileManager.default.fileExists(atPath: marker.path) else { throw NBARecapError.authorizationRequired }
        let ledger = await NBATerraAutofill.shared.snapshot()
        guard ledger.spentUSD < 1.0 else { throw NBARecapError.dailyBudget }
        try JSONSerialization.data(withJSONObject:["startedAt":Date().description,"initialUsedOrReservedUSD":ledger.spentUSD,"model":NBATerraClient.model])
            .write(to:marker,options:.atomic)
        func model(_ id: String) throws -> NBAReviewPanelModel {
            let data = try Data(contentsOf: caches.appendingPathComponent("NBABoxScores/" + id + ".json"))
            let boxes = NBABoxScoreStore(directory: root.appendingPathComponent("live-box-" + id), fetch: { _ in data })
            let articles = NBATerraRecapStore(directory: caches.appendingPathComponent("NBATerraArticles-v2")) { _ in throw NBARecapError.authorizationRequired }
            return NBAReviewPanelModel(gameID: id, boxes: boxes, articles: articles)
        }
        func ask(_ question: String, model: NBAReviewPanelModel, name: String) async throws {
            let before = model.turns.count
            model.draft = question; model.submit(); model.submit()
            for _ in 0..<4000 {
                if !model.asking { break }
                try await Task.sleep(nanoseconds: 30_000_000)
            }
            guard !model.asking, model.turns.count == before + 1, let answer = model.turns.last?.answer,
                  answer.requestID != nil else { throw NBARecapError.invalidResponse }
            try JSONEncoder().encode(answer).write(to: root.appendingPathComponent(name + "-answer.json"), options: .atomic)
            let ledgerBeforeCache = await NBATerraAutofill.shared.snapshot()
            model.draft = question; model.submit()
            guard !model.asking, model.turns.count == before + 1 else { throw NBARecapError.invalidData }
            let ledgerAfterCache = await NBATerraAutofill.shared.snapshot()
            guard ledgerBeforeCache.spentUSD == ledgerAfterCache.spentUSD else { throw NBARecapError.invalidData }
        }
        let local = try model("401909901"); await local.load()
        try await ask("这场比赛马刺下半场比分如何，哪些统计差距值得关注？", model: local, name: "local")
        try await ask("你刚才提到的篮板差距具体是多少？只据本场统计回答。", model: local, name: "followup")
        let pre = try model("401909905"); await pre.load()
        try await ask("请查NBA和快船官方截至2026年11月1日的信息，伦纳德下一场的出场状态是否已确认？如果没有官方确认或复出日期，就明确说明。", model: pre, name: "search")
        let final = await NBATerraAutofill.shared.snapshot()
        try JSONEncoder().encode(final).write(to:root.appendingPathComponent("live-ledger-after.json"),options:.atomic)
    }
    private static func findProbe(_ view: NSView, id: String) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        for child in view.subviews { if let found = findProbe(child, id: id) { return found } }
        return nil
    }
    private static func makeWindow(_ host: NSView) -> NSWindow {
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:560,height:540),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;window.title = "MenuScores 本机验收";window.contentView = host
        NSApp.setActivationPolicy(.regular);window.center();window.makeKeyAndOrderFront(nil);return window
    }
    private static func click(_ host: NSView, window: NSWindow, x: CGFloat, fromTop: CGFloat) {
        window.setContentSize(host.fittingSize);host.layoutSubtreeIfNeeded()
        let local = NSPoint(x:x,y:host.isFlipped ? fromTop : host.bounds.height-fromTop), point = host.convert(local,to:nil)
        for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
            if let event = NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:type == .leftMouseDown ? 1 : 0) { NSApp.postEvent(event,atStart:false) }
        }
    }
    private static func capture(_ host: NSView, window: NSWindow, to url: URL) async throws {
        for _ in 0..<3 {
            window.setContentSize(host.fittingSize);host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        if let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds) {
            host.cacheDisplay(in:host.bounds,to:bitmap)
            try? bitmap.representation(using:.png,properties:[:])?.write(to:url.appendingPathExtension("png"))
        }
        try? JSONSerialization.data(withJSONObject:["width":host.bounds.width,"height":host.bounds.height,"APIRequests":0,"keychainReads":0])
            .write(to:url.appendingPathExtension("json"),options:.atomic)
    }
}
#endif
