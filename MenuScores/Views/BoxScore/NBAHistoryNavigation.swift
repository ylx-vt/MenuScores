import SwiftUI

struct NBAHistoryNavigation: View {
    let day: Date
    let onBack: () -> Void
    let onToday: () -> Void

    private var dateTitle: String {
        NBASchedulePolicy.dayTitle(day)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .accessibilityLabel("返回当天比赛列表")
            Text(dateTitle).font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 12)
            Button("回到今日", action: onToday)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }
}
