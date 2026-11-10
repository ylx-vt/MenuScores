import SwiftUI

@MainActor struct NBAReviewPanelView: View {
    let gameID: String
    var initialRoute: NBAReviewPanelModel.Route = .score
    @StateObject private var model: NBAReviewPanelModel
    @State private var appeared = false
    @State private var contentHeights: [String: CGFloat] = [:]
    init(gameID: String, initialRoute: NBAReviewPanelModel.Route = .score, model: NBAReviewPanelModel? = nil) {
        self.gameID = gameID; self.initialRoute = initialRoute
        _model = StateObject(wrappedValue: model ?? NBAReviewSessions.model(gameID: gameID))
    }
    private var showsStatistics: Bool { model.route == .statistics || (model.route == .score && model.evidence?.isPregame != true) }
    var body: some View {
        ZStack(alignment: .topLeading) {
            // Keep the original statistics view mounted: switching to a recap
            // must not discard the selected team or its ScrollView position.
            NBABoxScoreView(gameID: gameID, boxStore: model.boxes,
                            onReviewRequested: { model.showSources = false; model.route = .recap },
                            onConversationRequested: { model.openConversation() }, conversationCount: model.conversationCount,
                            inlineReviewLead: model.articleModel.article?.lead,
                            embedsReviewOverview: true, presentationActive: showsStatistics,
                            onTeamSelectionChanged: { model.statisticsTeamID = $0 })
                .fixedSize(horizontal: true, vertical: true)
                .opacity(showsStatistics ? 1 : 0).allowsHitTesting(showsStatistics).accessibilityHidden(!showsStatistics)
                .frame(width: showsStatistics ? nil : 0, height: showsStatistics ? nil : 0).clipped()
                VStack(alignment: .leading, spacing: 0) {
                    navigation.padding(.bottom, 15)
                    scoreLine.frame(height: 50).padding(.bottom, 22)
                    ZStack(alignment: .topLeading) {
                        overview.opacity(model.route == .score ? 1 : 0).allowsHitTesting(model.route == .score).accessibilityHidden(model.route != .score)
                        expanded(.recap) { recap }.opacity(model.route == .recap ? 1 : 0).allowsHitTesting(model.route == .recap).accessibilityHidden(model.route != .recap)
                        expanded(.evidence) { evidence }.opacity(model.route == .evidence ? 1 : 0).allowsHitTesting(model.route == .evidence).accessibilityHidden(model.route != .evidence)
                        expanded(.question) { conversation }.opacity(model.route == .question ? 1 : 0).allowsHitTesting(model.route == .question).accessibilityHidden(model.route != .question)
                    }.frame(height: model.route == .score ? 99 : bodyHeight(model.route), alignment: .top).clipped()
                    if let error = model.error ?? model.articleModel.error {
                        Text(error).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                        if error.contains("钥匙串") || error.contains("本机") && error.contains("配置") { Button("打开安全配置") { NBATerraCredentialSetup.shared.show() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.blue) }
                    }
                    if let error = model.historyError {
                        HStack(alignment: .top) {
                            Text(error).font(.system(size: 11)).foregroundStyle(.orange)
                            Button("重试保存") { model.retryHistorySave() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.blue)
                        }.padding(.top, 5)
                    }
                    if model.route != .score { inputBar.padding(.top, 12) }
                }.padding(20).frame(width: 560).modifier(NBAPanelSurface())
                    .fixedSize(horizontal: true, vertical: true)
                    .opacity(showsStatistics ? 0 : 1).allowsHitTesting(!showsStatistics).accessibilityHidden(showsStatistics)
                    .frame(width: showsStatistics ? 0 : nil, height: showsStatistics ? 0 : nil).clipped()
        }
        .task {
            if !appeared { appeared = true; if initialRoute != .score { model.route = initialRoute } }
            await model.load()
        }
        .onDisappear { model.leave() }
        .onPreferenceChange(NBAReviewContentHeight.self) { contentHeights = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .terraArticlePrepared).receive(on: RunLoop.main)) { value in
            if value.object as? String == gameID { Task { await model.load() } }
        }
    }
    private func bodyHeight(_ route: NBAReviewPanelModel.Route) -> CGFloat {
        if route == .evidence { return 360 }
        if route == .question {
            return min(326, max(180, contentHeights[route.rawValue] ?? 180))
        }
        return min(326, max(140, contentHeights[route.rawValue] ?? 326))
    }
    private var navigation: some View {
        HStack(spacing: 12) {
            if model.route != .score {
                Button(action: back) { Label(model.showSources ? "正文" : model.route == .recap ? "比分" : model.route == .evidence ? "回复盘" : model.questionBack == .evidence ? "回证据" : "回复盘", systemImage: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(.blue).font(.system(size: 13)).frame(width: 60, alignment: .leading)
            } else { Color.clear.frame(width: 60, height: 19) }
            Text(model.evidence?.isPregame == true ? "赛前 · 北京时间" : "比赛解读 · 北京时间")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 2)
            if model.hasConversation, model.route != .question {
                Button("对话 \(model.conversationCount)") { model.openConversation() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.blue)
            }
            if model.isLoading { ProgressView().controlSize(.mini) }
            Button("技术统计") { model.route = .statistics }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.blue)
                .help("查看球队与球员技术统计")
            Button { Task { await model.load(force: true) } } label: {
                Text(model.evidence.map { time($0.dataAsOf) } ?? (model.error == nil ? "正在读取" : "重试"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.buttonStyle(.plain).help("刷新公开数据和缓存，不调用模型")
        }.frame(height: 19)
    }
    private var scoreLine: some View {
        HStack(spacing: 11) {
            if let away = model.evidence?.away, let home = model.evidence?.home {
                logo(away)
                Text(away.name).font(.system(size: 14, weight: .medium)).lineLimit(1).minimumScaleFactor(0.95)
                Text(away.score.map(String.init) ?? "—").font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit().fixedSize()
                Spacer(minLength: 0)
                VStack(spacing: 4) {
                    Text(model.evidence?.isPregame == true ? model.evidence?.matchDate.map { NBASchedulePolicy.startTime($0) } ?? "待定" : model.evidence?.isFinal == true ? "全场结束" : "比赛进行中")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Rectangle().fill(Color.secondary.opacity(0.24)).frame(width: 1, height: 9)
                }
                Spacer(minLength: 0)
                Text(home.score.map(String.init) ?? "—").font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit().fixedSize()
                Text(home.name).font(.system(size: 14, weight: .medium)).lineLimit(1).minimumScaleFactor(0.95)
                logo(home)
            } else {
                Image(systemName: "basketball").font(.system(size: 28)).foregroundStyle(.secondary)
                Text(model.error == nil ? "正在确认双方与比分" : "资料暂未取得").font(.system(size: 15)).foregroundStyle(.secondary)
                Spacer()
            }
        }.accessibilityElement(children: .combine)
    }
    private func logo(_ side: NBAReviewEvidence.Side) -> some View {
        Group {
            if let image = NBATeamLogo.bundledImage(url: nil, teamID: side.id, abbreviation: side.abbreviation) { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "basketball").resizable().scaledToFit().foregroundStyle(.secondary) }
        }.frame(width: 42, height: 42).accessibilityHidden(true)
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.articleModel.article?.title ?? (model.error != nil && model.evidence == nil ? "比赛资料暂时不可用" : model.evidence?.isPregame == true ? "先看双方的真实差异" : "从比分，走进这场比赛"))
                .font(.system(size: 16, weight: .regular)).lineLimit(2)
            HStack(alignment: .top, spacing: 12) {
                Text(model.articleModel.article?.lead ?? model.evidence?.coverageNote ?? "资料正在准备，暂不推断比赛过程。")
                    .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2).lineSpacing(3)
                Spacer(minLength: 0)
                Button { model.route = .recap } label: { HStack(spacing: 3) { Text(model.evidence?.isPregame == true ? "看这场" : "读懂这场"); Image(systemName: "chevron.right") } }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.blue).fixedSize().disabled(model.evidence == nil)
            }
        }
    }
    private func expanded<Content: View>(_ route: NBAReviewPanelModel.Route, @ViewBuilder content: @escaping () -> Content) -> some View {
        ZStack(alignment: .topLeading) {
            ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 5)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: NBAReviewContentHeight.self, value: [route.rawValue: geometry.size.height])
                    })
                    .background {
                        #if DEBUG
                        NBAReviewScrollProbe(route: route.rawValue).frame(width: 0, height: 0)
                        #endif
                    }
            }.opacity(model.showSources && model.route == route ? 0 : 1)
                .allowsHitTesting(!(model.showSources && model.route == route))
                .accessibilityHidden(model.showSources && model.route == route)
                .onChange(of: model.turns.last?.id) { _ in if route == .question { reader.scrollTo("review-question-bottom", anchor: .bottom) } }
            }
            if model.showSources && model.route == route {
                ScrollView { sourceList.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 5) }
            }
        }.frame(height: bodyHeight(route)).id(route.rawValue)
    }
    private var recap: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.evidence?.isPregame == true ? "赛前看点" : "复盘要点").font(.system(size: 16, weight: .regular))
            Text(model.articleModel.article?.lead ?? model.evidence?.coverageNote ?? "资料待更新")
                .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(3)
            if let evidence = model.evidence {
                ForEach(evidence.segments) { segment in
                    Button { model.openEvidence(segment) } label: {
                        HStack(alignment: .top, spacing: 14) {
                            Rectangle().fill(segment.id == model.selectedSegmentID ? Color.blue : .clear).frame(width: 2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(segment.title).font(.system(size: 14, weight: .regular))
                                Text(segment.time).font(.system(size: 11.5)).lineSpacing(2)
                            }.foregroundStyle(segment.id == model.selectedSegmentID ? Color.blue : .primary).frame(width: 124, alignment: .leading)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(segment.headline).font(.system(size: 14, weight: .regular))
                                Text(segment.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(2)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(segment.id == model.selectedSegmentID ? Color.blue : .secondary)
                        }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 7).contentShape(Rectangle())
                            .overlay(alignment: .top) { Divider().opacity(0.45) }
                    }.buttonStyle(.plain)
                }
            }
            DisclosureGroup("完整文字解读", isExpanded: $model.showFullArticle) {
                if let article = model.articleModel.article {
                    ForEach(Array((article.paragraphs ?? [article.text]).enumerated()), id: \.offset) { _, text in
                        Text(text).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled).padding(.vertical, 4)
                    }
                    Text("Terra · " + time(article.generatedAt) + " · 已有缓存").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text("还没有本场文字解读；现有数据片段可先查看。生成会使用每日共享额度。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Button(model.articleModel.isLoading ? "正在生成…" : "生成文字解读") { model.articleModel.generate(enabled: NBATerraOptions.enabled()) }
                        .buttonStyle(.plain).foregroundStyle(.blue).disabled(model.articleModel.isLoading || !model.articleModel.sourceFresh)
                }
            }.font(.system(size: 12)).tint(.blue)
            HStack {
                Button("来源") { model.showSources = true }.foregroundStyle(.blue)
            }.buttonStyle(.plain).font(.system(size: 11))
        }
    }
    private var evidence: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(model.evidence?.isPregame == true ? "看点的依据" : "这一段的依据").font(.system(size: 16, weight: .regular))
            Text(model.evidence?.coverageNote ?? "资料待更新").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
            if let evidence = model.evidence {
                NBAReviewChart(evidence: evidence, segment: model.segment) { model.selectedPointID = $0 }
                if let point = evidence.points.first(where: { $0.id == model.selectedPointID }) {
                    Text(point.label + " · 原始事件\n" + point.text).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                observation("观察", color: .blue, headline: model.segment?.headline ?? "资料待更新", detail: model.segment?.detail ?? "没有足够数据。")
                observation("待核实", color: .secondary, headline: evidence.isPregame ? "本场出场情况" : "是否存在战术原因", detail: evidence.pending)
                Button { model.showSources = true } label: { Label("查看依据", systemImage: "chevron.right") }.buttonStyle(.plain).foregroundStyle(.blue).font(.system(size: 12))
            }
        }
    }
    private func observation(_ title: String, color: Color, headline: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            HStack(spacing: 6) { Circle().fill(color).frame(width: 9, height: 9); Text(title).font(.system(size: 13)) }
                .foregroundStyle(color).frame(width: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline).font(.system(size: 13, weight: .regular))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
            }
            Spacer(minLength: 0)
            Button { model.showSources = true } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain).foregroundStyle(.blue)
        }.padding(.vertical, 8).overlay(alignment: .top) { Divider().opacity(0.4) }
    }
    private var conversation: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.turns.isEmpty && model.historyAttempt == nil {
                Text(model.asking ? model.draft : "还想知道什么？").font(.system(size: 16, weight: .regular))
                Text(model.asking ? "正在核对当前比赛资料…" : "可以追问这一段的比分变化，也可以按需查公开报道。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            ForEach(model.turns) { turn in
                VStack(alignment: .leading, spacing: 12) {
                    Text(turn.question).font(.system(size: 16, weight: .regular))
                    if !turn.questionKnown || turn.evidenceFingerprint != nil && turn.evidenceFingerprint != model.evidence?.fingerprint {
                        Text("历史回答，保留当时资料与时间").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    if let context = turn.contextLabel { Text(context).font(.system(size: 11)).foregroundStyle(.secondary) }
                    NBAAnswerMarkdownView(answer: turn.answer)
                    if !turn.answer.sources.isEmpty {
                        Text("参考来源").font(.system(size: 13))
                        ForEach(turn.answer.sources) { source in sourceRow(source) }
                    } else if turn.answer.searched {
                        Text("外部资料未取得可核引用").font(.system(size: 11)).foregroundStyle(.secondary)
                    } else if let evidence = model.evidence {
                        Link("依据：ESPN 本场公开资料", destination: evidence.sourceURL).font(.system(size: 12))
                    }
                    if let local = turn.answer.localEvidence {
                        DisclosureGroup(local.events.isEmpty ? "身份与资料依据" : "本场查询依据 · \(local.events.count)条事件") {
                            Text(local.summaries.joined(separator:"\n")).font(.system(size:11)).foregroundStyle(.secondary).lineSpacing(3)
                            Text("比赛：" + (local.matchDate.flatMap(NBASchedulePolicy.startDate).map { time($0) } ?? "未提供") + " · 数据截至 " + time(local.dataAsOf)).font(.system(size:10.5)).foregroundStyle(.secondary)
                            ForEach(local.events) { event in
                                VStack(alignment:.leading,spacing:4) {
                                    Link(event.label + " · " + event.score, destination:event.url).font(.system(size:12))
                                    Text(event.text).font(.system(size:12)).foregroundStyle(.secondary).textSelection(.enabled)
                                    Text("事件 " + event.id).font(.system(size:10)).foregroundStyle(.secondary)
                                }.padding(.vertical,4)
                            }
                            ForEach(local.identitySources ?? []) { source in sourceRow(source) }
                        }.font(.system(size:12)).tint(.blue)
                    }
                    if let warning = turn.answer.searchWarning { Text(warning).font(.system(size: 11)).foregroundStyle(.secondary) }
                    Text((turn.answer.isEvidenceNotice || turn.answer.requestID == nil && turn.answer.usage == nil ? "资料提示 · " : "Terra · ") + time(turn.answer.generatedAt) + (turn.answer.searched ? " · 已按需查证" : " · 据本场资料"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if turn.answer.isEvidenceNotice, turn.questionKnown {
                        Button("重新分析此问") { model.retry(turn) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.blue).disabled(model.asking)
                            .help("保留这条历史，按当前策略新增一条回答；费用共用每日上限")
                    }
                }.padding(.bottom, 12)
                Divider().opacity(0.4)
            }
            if let attempt = model.historyAttempt {
                VStack(alignment:.leading,spacing:8) {
                    Text(attempt.question).font(.system(size:15,weight:.regular)).textSelection(.enabled)
                    if let context = attempt.contextLabel { Text(context).font(.system(size:11)).foregroundStyle(.secondary) }
                    if model.asking {
                        HStack { ProgressView().controlSize(.small);Text("正在分析，收起面板后仍会继续…") }.font(.system(size:12)).foregroundStyle(.secondary)
                    } else {
                        Text(attempt.state == "cancelled" ? "已取消" : attempt.state == "interrupted" ? "应用退出后中断，未自动重发" : "未完成，原问已保存").font(.system(size:12)).foregroundStyle(.secondary)
                        Button("重试此问") { model.retryAttempt() }.buttonStyle(.plain).font(.system(size:12)).foregroundStyle(.blue)
                    }
                }.padding(.vertical,10)
            }
            Color.clear.frame(height: 1).id("review-question-bottom")
        }
    }
    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("数据与来源").font(.system(size: 16, weight: .regular))
            if let evidence = model.evidence {
                Link(destination: evidence.sourceURL) { Label("ESPN 比赛原始资料", systemImage: "doc.text") }.font(.system(size: 13))
                Text("数据截至 " + time(evidence.dataAsOf)).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(evidence.coverageNote).font(.system(size: 12)).foregroundStyle(.secondary)
                if let segment = model.segment {
                    Text(segment.time + "\n" + segment.headline + "\n" + segment.detail).font(.system(size: 13)).lineSpacing(4)
                    Text(segment.evidenceIDs.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                DisclosureGroup("已使用的公开事实") {
                    Text((try? evidence.questionFacts(segmentID: model.selectedSegmentID)) ?? "资料未提供")
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }.font(.system(size: 12))
            }
            ForEach(model.turns.last?.answer.sources ?? []) { source in sourceRow(source) }
        }
    }
    private func sourceRow(_ source: NBAReviewAnswer.Source) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Link(destination: source.url) {
                HStack(spacing: 10) { Image(systemName: "doc.text"); Text(source.title).lineLimit(2); Spacer(); Image(systemName: "arrow.up.right.square") }
            }.font(.system(size: 13)).foregroundStyle(.blue)
            if let kind = source.evidenceKind { Text(kind).font(.system(size: 10.5)).foregroundStyle(.secondary) }
            Text("发布：" + (source.publishedAt ?? "未提供") + (source.pageFetched == true ? " · 抓取 " : " · 检索 ") + time(source.fetchedAt))
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
        }.padding(.vertical, 5)
    }
    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(model.route == .question ? "继续问这场…" : "还想知道什么？", text: $model.draft)
                .textFieldStyle(.plain).font(.system(size: 13)).onSubmit { model.submit() }
                .disabled(!model.questionsAllowed)
            if model.asking {
                Button("取消") { model.cancelQuestion() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button { model.submit() } label: {
                Image(systemName: "arrow.up").font(.system(size: 18, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 31, height: 31).background(Color.blue, in: Circle())
            }.buttonStyle(.plain).disabled(model.asking || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.questionsAllowed)
                .help("发送本场追问；需要时查公开资料，费用共用每日 $\(NBATerraAutofill.dailyLimitText) 上限")
        }.padding(.leading, 14).padding(.trailing, 5).padding(.vertical, 5)
            .background(Color.primary.opacity(0.025), in: Capsule())
            .overlay(Capsule().stroke(Color.secondary.opacity(0.14), lineWidth: 0.6))
    }
    private func back() {
        if model.showSources { model.showSources = false; return }
        switch model.route { case .recap: model.route = .score; case .evidence: model.route = .recap; case .question: model.route = model.questionBack; default: model.route = .score }
    }
    private func time(_ date: Date) -> String { NBASchedulePolicy.startTime(date, includeDay: true) }
}

private struct NBAReviewContentHeight: PreferenceKey {
    static var defaultValue: [String: CGFloat] { [:] }
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) { value.merge(nextValue(), uniquingKeysWith: { _, next in next }) }
}

struct NBAReviewChart: View {
    let evidence: NBAReviewEvidence
    let segment: NBAReviewEvidence.Segment?
    var onSelectPoint: (String) -> Void = { _ in }
    private var nodes: [NBAReviewEvidence.Point] {
        guard !evidence.points.isEmpty else { return [] }
        let start = segment?.start ?? 0, end = segment?.end ?? evidence.points.count - 1
        let indices = Array(Set([start, (start + end) / 2, end])).sorted()
        return indices.compactMap { evidence.points.indices.contains($0) ? evidence.points[$0] : nil }
            .filter { point in evidence.chartPoints.contains(where: { $0.id == point.id }) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if evidence.isPregame {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(evidence.input?.facts.teams ?? [], id: \.id) { team in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(team.name).font(.system(size: 12))
                            Text(team.record ?? "战绩待更新").font(.system(size: 20, weight: .medium, design: .rounded))
                            Text("场均 " + (team.statistics["seasonAveragePoints"] ?? "—") + "分").font(.system(size: 12)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(12).frame(height: 125).background(Color.blue.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            } else if !evidence.points.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(nodes.enumerated()), id: \.element.id) { index, point in
                        Button { onSelectPoint(point.id) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) { Text("\(index + 1)").font(.system(size: 10, weight: .medium)).foregroundStyle(.white).frame(width: 15, height: 15).background(.blue, in: Circle()); Text("\(point.away)–\(point.home)").font(.system(size: 12)) }
                            Text(point.label).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }
                GeometryReader { geometry in
                    let points = evidence.chartPoints, width = geometry.size.width - 42, height = geometry.size.height - 20
                    let limit = Double(max(15, Int(ceil(Double(points.map { abs($0.margin) }.max() ?? 15) / 5)) * 5))
                    let lastTime = max(2880, evidence.points.map(\.elapsed).max() ?? 2880)
                    let chart = CGRect(x: 36, y: 4, width: width, height: height)
                    let path = line(points, chart: chart, limit: limit, time: lastTime)
                    Path { p in p.move(to: CGPoint(x: chart.minX, y: chart.midY)); p.addLine(to: CGPoint(x: chart.maxX, y: chart.midY)) }
                        .stroke(Color.secondary.opacity(0.22), lineWidth: 0.6)
                    path.stroke(Color.blue, lineWidth: 1.6).mask(Rectangle().frame(height: chart.midY).frame(maxHeight: .infinity, alignment: .top))
                    path.stroke(Color.red.opacity(0.8), lineWidth: 1.6).mask(Rectangle().frame(height: geometry.size.height - chart.midY).frame(maxHeight: .infinity, alignment: .bottom))
                    ForEach(nodes) { point in
                        let x = chart.minX + point.elapsed / lastTime * chart.width
                        let y = chart.midY - Double(point.margin) / limit * chart.height / 2
                        Path { p in p.move(to: CGPoint(x: x, y: chart.minY)); p.addLine(to: CGPoint(x: x, y: chart.maxY)) }
                            .stroke(Color.blue.opacity(0.25), style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
                        Circle().fill(Color.blue).frame(width: 7, height: 7).position(x: x, y: y)
                    }
                    VStack { Text("+\(Int(limit))"); Spacer(); Text("0"); Spacer(); Text("−\(Int(limit))") }
                        .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 30, height: chart.height).position(x: 14, y: chart.midY)
                    HStack { Text("开场"); Spacer(); Text(evidence.coverage == .complete ? "完赛" : "最后已知事件") }
                        .font(.system(size: 10)).foregroundStyle(.secondary).padding(.leading, 36).frame(maxHeight: .infinity, alignment: .bottom)
                }.frame(height: 119)
                Text("分差：" + (evidence.home?.name ?? "主队") + "领先为正 · 节点为真实记录，不作平滑补点")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(evidence.coverage == .periods ? "节末节点" : "逐回合尚未提供").font(.system(size: 13))
                    HStack(spacing: 16) {
                        ForEach(evidence.input?.facts.periods ?? [], id: \.number) { period in
                            VStack(spacing: 6) { Text("Q\(period.number)").foregroundStyle(.blue); Text("\(period.awayPoints)–\(period.homePoints)") }
                                .font(.system(size: 12)).frame(maxWidth: .infinity)
                        }
                    }
                    Text("缺失的曲线与事件节点保持空白，不推断节内走势。").font(.system(size: 12)).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
                    .background(Color.blue.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
    private func line(_ points: [NBAReviewEvidence.Point], chart: CGRect, limit: Double, time: Double) -> Path {
        Path { path in
            var previous: CGPoint?
            for point in points {
                let position = CGPoint(x: chart.minX + point.elapsed / time * chart.width, y: chart.midY - Double(point.margin) / limit * chart.height / 2)
                if let previous, !point.correction {
                    path.addLine(to: CGPoint(x: position.x, y: previous.y)); path.addLine(to: position)
                } else { path.move(to: position) }
                previous = position
            }
        }
    }
}

#if DEBUG
private struct NBAReviewScrollProbe: NSViewRepresentable {
    let route: String
    func makeNSView(context: Context) -> NSView {
        let view = NSView(); view.identifier = NSUserInterfaceItemIdentifier("review-scroll-probe-" + route); return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
