import Foundation

enum NBALoadingPolicy {
    static let liveInterval: TimeInterval = 15
    static let rankingInterval: TimeInterval = 900

    static func summaryDelay(state: String?, fetchedAt: Date, refreshFailed: Bool, now: Date = Date()) -> TimeInterval {
        guard state == "post" else { return liveInterval }
        if refreshFailed { return 60 }
        return max(1, NBABoxScoreStore.completedTTL - now.timeIntervalSince(fetchedAt))
    }

    static func cacheCaption(stale: Bool, failed: Bool) -> String? {
        if failed { return "更新失败 · 显示缓存" }
        return stale ? "缓存数据" : nil
    }
}
