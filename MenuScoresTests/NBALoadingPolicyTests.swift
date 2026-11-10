import Foundation
import Testing
@testable import MenuScores

struct NBALoadingPolicyTests {
    @Test func completedGamesWaitUntilExpiryWhileLiveKeepsItsCadence() {
        let fetched = Date(timeIntervalSince1970: 1000)
        #expect(NBALoadingPolicy.summaryDelay(state: "post", fetchedAt: fetched, refreshFailed: false, now: fetched) == 21600)
        #expect(NBALoadingPolicy.summaryDelay(state: "post", fetchedAt: fetched, refreshFailed: false, now: fetched.addingTimeInterval(60)) == 21540)
        #expect(NBALoadingPolicy.summaryDelay(state: "post", fetchedAt: fetched, refreshFailed: false, now: fetched.addingTimeInterval(21600)) == 1)
        #expect(NBALoadingPolicy.summaryDelay(state: "post", fetchedAt: fetched, refreshFailed: true, now: fetched.addingTimeInterval(21600)) == 60)
        for state in ["in", "pre", nil] {
            #expect(NBALoadingPolicy.summaryDelay(state: state, fetchedAt: fetched, refreshFailed: true, now: fetched) == 15)
        }
    }

    @Test func failedAndStaleValuesHaveVisibleStatus() {
        #expect(NBALoadingPolicy.cacheCaption(stale: false, failed: false) == nil)
        #expect(NBALoadingPolicy.cacheCaption(stale: true, failed: false) == "缓存数据")
        #expect(NBALoadingPolicy.cacheCaption(stale: false, failed: true) == "更新失败 · 显示缓存")
        #expect(NBALoadingPolicy.cacheCaption(stale: true, failed: true) == "更新失败 · 显示缓存")
    }
}
