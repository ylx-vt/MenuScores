import SwiftUI

struct NBASeasonPerformanceSummary: View {
    let rating: NBASeasonRating?
    @State private var showingExplanation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text("球员表现").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Button { showingExplanation = true } label: {
                    Image(systemName: "info.circle").font(.system(size: 10))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("球员表现说明")
                .popover(isPresented: $showingExplanation) {
                    NBASeasonPerformanceExplanation(rating: rating) { showingExplanation = false }
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let rating, let position = rating.position, let estimate = rating.estimate {
                    Text("表现分 \(estimate.display)")
                        .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                    Spacer(minLength: 2)
                    Text("\(position.rank) / \(position.population)")
                        .font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                        .accessibilityLabel(rating.rankText)
                } else {
                    Text(rating?.performance == nil ? "暂无表现数据" : "样本积累中")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 9)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 7))
        .help(rating?.helpText ?? "暂无球员表现数据。")
        .accessibilityElement(children: .contain)
    }
}

struct NBASeasonPerformanceExplanation: View {
    var rating: NBASeasonRating? = nil
    let onClose: () -> Void
    @State private var showingDetails = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("球员表现").font(.headline)
                Text("表现分结合上季与本季数据；随着本季出场增加，本季数据的权重会提高。颜色按数据表现分档，虚线表示样本仍在积累。")
                Text("历史比赛中也显示当前可用的赛季评级，并非比赛当日评级。")
                    .foregroundStyle(.secondary)
                DisclosureGroup("计算细节", isExpanded: $showingDetails) {
                    calculationDetails.padding(.top, 8)
                }
                Button("关闭", action: onClose).keyboardShortcut(.cancelAction)
            }
            .font(.system(size: 11)).padding(16)
        }
        .frame(width: 370, height: showingDetails ? 520 : 225)
    }

    private var calculationDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let performance = rating?.performance {
                Text("本季原始EFF \(performance.display) · 实际\(performance.sampleText)")
            }
            if let estimate = rating?.estimate {
                Text(estimate.priorDescription)
                if let prior = estimate.prior {
                    Text("上季原始EFF \(prior.display) · 实际\(prior.sampleText)")
                    let priorMinutes = prior.minutes.map { String(format: "%.2f", Double($0) / Double(prior.games)) } ?? "缺失"
                    let currentMinutes = estimate.current.minutes.map { String(format: "%.2f", Double($0) / Double(estimate.current.games)) } ?? "缺失"
                    Text("场均分钟：上季\(priorMinutes)，本季\(currentMinutes)（仅对照，不调整权重）")
                }
                Text(String(format: "本季权重%.2f%% · 历史权重%.2f%%", estimate.currentWeight.value * 100, estimate.historicalWeight.value * 100))
                Text(estimate.evidenceText)
                if let date = estimate.priorDate { Text("上季数据获取时间：\(date.formatted(date: .numeric, time: .shortened))") }
                if !estimate.isEligible { Text("暂不分档原因：" + estimate.waitingReasons.joined(separator: "；")) }
            }
            Divider()
            Text("EFF = 得分＋篮板＋助攻＋抢断＋盖帽－投篮不中－罚球不中－失误；累计EFF除实际出场数，是本季原始场均。")
            Text("表现分 =（本季累计EFF＋历史等效场次×上季场均EFF）／（本季实际场数＋历史等效场次）。只用紧邻上季、同阶段；上季须实际至少3场及60分钟。历史等效场次 = 20×上季GP／（上季GP＋20）。")
            Text("所有人均须本季实际至少3场及60分钟，有效证据至少10场及200分钟。有效场次＝本季GP＋历史等效场次；有效分钟＝本季分钟＋历史等效场次×上季场均分钟。无有效历史时历史权重为0，适用相同门槛。")
            Text("历史等效量不是独立实际样本，10场/200分钟是产品最低证据量，不是稳定性或置信保证。这是基础技术统计表现，不代表全面实力或完整攻防影响，未经开季逐场回测。")
            Text("同分同名次，档位按名次／参评人数；单项卡片按各自ESPN有效达标池比较。低失误只表示数量少。本场数字比较不变。")
        }
    }
}
