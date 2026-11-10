import Foundation
import Testing
@testable import MenuScores

private func pregameFixture(_ name: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/NBA-pregame-\(name).json"))
}
private func pregameObject() throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: pregameFixture("summary")) as! [String: Any]
}
private func pregameDecode(_ value: [String: Any]) throws -> NBAPregamePreview {
    try JSONDecoder().decode(NBAPregamePreview.self, from: JSONSerialization.data(withJSONObject: value))
}

struct NBAPregamePreviewTests {
    private let scope = NBAPregamePreview.Scope(year: 2027, stage: 2)
    private func schedules() throws -> [String: NBAPregamePreview.Schedule] {
        ["13": try NBAPregameScheduleStore.decode(pregameFixture("lakers-schedule"), teamID: "13", scope: scope),
         "9": try NBAPregameScheduleStore.decode(pregameFixture("warriors-schedule"), teamID: "9", scope: scope)]
    }

    @Test func existingSummaryDecoderExposesPregameAndLogosAndSwitchesBackOnTipoff() throws {
        let data = try pregameFixture("summary")
        let summary = try JSONDecoder().decode(NBABoxScore.self, from: data)
        #expect(summary.hasPregamePresentation)
        #expect(summary.pregame?.eventID == "401909285")
        #expect(summary.match?.competitors?.first?.team.logo?.hasSuffix("gs.png") == true)
        var object = try pregameObject(); var header = object["header"] as! [String: Any]
        var matches = header["competitions"] as! [[String: Any]]
        matches[0]["status"] = ["type": ["state": "in", "name": "STATUS_IN_PROGRESS", "completed": false]]
        header["competitions"] = matches; object["header"] = header
        let started = try JSONDecoder().decode(NBABoxScore.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!started.hasPregamePresentation)
        #expect(started.pregame?.isPregame == false)
    }

    @Test func pregameCadenceAvoidsLivePollingAndFallbackKeepsKnownMatchWithoutStatistics() throws {
        let now = NBASchedulePolicy.startDate("2026-10-30T04:00Z")!
        #expect(NBAPregamePreview.pollingInterval(start: now.addingTimeInterval(3600), now: now) == 300)
        #expect(NBAPregamePreview.pollingInterval(start: now.addingTimeInterval(910), now: now) == 10)
        #expect(NBAPregamePreview.pollingInterval(start: now, now: now) == 30)
        let game = try JSONDecoder().decode(Event.self, from: Data(#"{"id":"1","date":"2026-10-31T02:00Z","name":"LAL at GS","status":{"type":{"state":"pre","completed":false}},"competitions":[{"status":{"type":{"state":"pre","completed":false}},"competitors":[{"id":"13","homeAway":"away","team":{"id":"13","abbreviation":"LAL","links":[]}},{"id":"9","homeAway":"home","team":{"id":"9","abbreviation":"GS","links":[]}}]}]}"#.utf8))
        let fallback = try #require(NBAPregamePreview.fallback(event: game))
        #expect(fallback.teams().map { $0.team.name } == ["湖人", "勇士"])
        #expect(fallback.startDate == NBASchedulePolicy.startDate("2026-10-31T02:00Z"))
        #expect(fallback.scope == nil && fallback.teams().allSatisfy { $0.points == nil && $0.recentGames.isEmpty })
    }

    @Test func realSummaryKeepsSeasonAveragesButRequiresEvidenceForUnscopedRecentRows() throws {
        let preview = try JSONDecoder().decode(NBAPregamePreview.self, from: pregameFixture("summary"))
        #expect(preview.eventID == "401909285" && preview.isPregame)
        #expect(preview.scope == scope)
        #expect(preview.scope?.title == "2026–27 常规赛")
        let cards = preview.teams()
        #expect(cards.map(\.id) == ["13", "9"])
        #expect(cards.map(\.record) == ["4-1", "2-3"])
        #expect(cards.map(\.points) == [123.2, 117.6])
        #expect(cards.map(\.pointsAgainst) == [113.6, 119.4])
        #expect(cards.allSatisfy { $0.needsSchedule && $0.recentGames.isEmpty && $0.offDays == nil })
        #expect(cards[0].team.logoURL?.hasSuffix("lal.png") == true)
        #expect(cards[1].team.logoURL?.hasSuffix("gs.png") == true)
        #expect(preview.officialReportURL?.absoluteString == "https://official.nba.com/nba-injury-report-2026-27-season/")
    }

    @Test func realSchedulesRestoreFiveGamesAndReconcileSeasonPointsWithoutAssumingArrayOrder() throws {
        let preview = try JSONDecoder().decode(NBAPregamePreview.self, from: pregameFixture("summary"))
        let cards = preview.teams(schedules: try schedules())
        #expect(cards.allSatisfy { !$0.needsSchedule && $0.recentGames.count == 5 })
        #expect(cards[0].recentGames.map(\.won) == [true, false, true, true, true])
        #expect(cards[1].recentGames.map(\.won) == [true, true, false, false, false])
        #expect(cards.map(\.offDays) == [1, 1])
        #expect(cards.map(\.scoringLeaderPoints) == [36, 28.8])
        for card in cards {
            #expect(Double(card.recentGames.reduce(0) { $0 + $1.points }) / 5 == card.points)
            #expect(Double(card.recentGames.reduce(0) { $0 + $1.opponentPoints }) / 5 == card.pointsAgainst)
        }
        #expect(preview.insight(schedules: try schedules()) == "勇士近2场全胜。本季上次交锋，湖人以127–105取胜。")
    }

    @Test func explicitlyScopedRecentRowsExcludePreseasonFutureLiveAndDuplicateEvents() throws {
        var object = try pregameObject()
        var groups = object["lastFiveGames"] as! [[String: Any]]
        for index in groups.indices {
            var events = groups[index]["events"] as! [[String: Any]]
            events = events.map { item in
                var row = item; row["season"] = ["year": 2027]; row["seasonType"] = ["type": 2]; return row
            }
            var preseason = events[0]; preseason["id"] = "preseason"; preseason["seasonType"] = ["type": 1]
            var future = events[0]; future["id"] = "future"; future["gameDate"] = "2026-11-01T02:00Z"
            var live = events[0]; live["id"] = "live"; live["status"] = ["type": ["state": "in", "completed": false]]
            var cancelled = events[0]; cancelled["id"] = "cancelled"; cancelled["gameDate"] = "2026-10-30T02:00Z"
            cancelled["status"] = ["type": ["state": "post", "completed": true, "name": "STATUS_CANCELED"]]
            events += [preseason, future, live, cancelled, events[0]]
            groups[index]["events"] = events.reversed().map { $0 }
        }
        object["lastFiveGames"] = groups
        let cards = try pregameDecode(object).teams()
        #expect(cards.allSatisfy { !$0.needsSchedule && $0.recentGames.count == 5 })
        #expect(cards[0].recentGames.map(\.won) == [true, false, true, true, true])
        #expect(cards.flatMap(\.recentGames).allSatisfy { !["preseason", "future", "live", "cancelled"].contains($0.id) })
    }

    @Test func missingAndMalformedSectionsKeepTeamIdentityAndOtherValidValues() throws {
        var object = try pregameObject()
        object["lastFiveGames"] = ["malformed", NSNull()]
        object["leaders"] = ["malformed"]
        var box = object["boxscore"] as! [String: Any]
        var teams = box["teams"] as! [[String: Any]]
        teams[0]["statistics"] = [["name": "avgPoints", "displayValue": "NaN"], ["name": "avgPointsAgainst", "displayValue": 113.6], "bad"]
        box["teams"] = teams; object["boxscore"] = box
        let preview = try pregameDecode(object)
        let cards = preview.teams()
        #expect(cards.count == 2)
        #expect(cards[0].record == "4-1" && cards[0].points == nil && cards[0].pointsAgainst == 113.6)
        #expect(cards[1].points == 117.6)
        #expect(cards.allSatisfy { $0.scoringLeader == nil })
    }

    @Test func missingSeasonKeepsRecordsAndIdentityWithoutMislabelingStatistics() throws {
        var object = try pregameObject()
        var header = object["header"] as! [String: Any]
        header.removeValue(forKey: "season"); object["header"] = header
        let preview = try pregameDecode(object)
        #expect(preview.scope == nil)
        #expect(preview.teams().map(\.record) == ["4-1", "2-3"])
        #expect(preview.teams().allSatisfy { $0.points == nil && $0.scoringLeaderPoints == nil && $0.recentGames.isEmpty })
        var matches = header["competitions"] as! [[String: Any]]
        matches[0].removeValue(forKey: "competitors"); header["competitions"] = matches; object["header"] = header
        #expect(try pregameDecode(object).teams().map(\.id) == ["13", "9"])
    }

    @Test func verifiedScheduleRejectsOtherTeamSeasonAndStageAndFiltersCancelledRows() throws {
        let data = try pregameFixture("lakers-schedule")
        #expect(throws: (any Error).self) { try NBAPregameScheduleStore.decode(data, teamID: "9", scope: scope) }
        #expect(throws: (any Error).self) { try NBAPregameScheduleStore.decode(data, teamID: "13", scope: .init(year: 2026, stage: 2)) }
        #expect(throws: (any Error).self) { try NBAPregameScheduleStore.decode(data, teamID: "13", scope: .init(year: 2027, stage: 1)) }
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var events = object["events"] as! [[String: Any]]
        var wrongStage = events[0]; wrongStage["id"] = "preseason"; wrongStage["seasonType"] = ["type": 1]
        var cancelled = events[0]; cancelled["id"] = "cancelled"
        var competition = (cancelled["competitions"] as! [[String: Any]])[0]
        competition["status"] = ["type": ["state": "post", "completed": true, "name": "STATUS_CANCELED"]]
        cancelled["competitions"] = [competition]
        events += [wrongStage, cancelled, events[0]]; object["events"] = events
        let schedule = try NBAPregameScheduleStore.decode(JSONSerialization.data(withJSONObject: object), teamID: "13", scope: scope)
        #expect(schedule.games.count == 5)
        #expect(schedule.games.allSatisfy { !["preseason", "cancelled"].contains($0.id) })
    }

    @Test func dayGapsUseBeijingCalendarAcrossYearAndIgnoreForeignOffsets() throws {
        var object = try pregameObject()
        var header = object["header"] as! [String: Any]
        var matches = header["competitions"] as! [[String: Any]]
        matches[0]["date"] = "2027-01-01T10:00:00+08:00"; header["competitions"] = matches; object["header"] = header
        let preview = try pregameDecode(object)
        let first = NBAPregamePreview.Game(id: "prior", date: NBASchedulePolicy.startDate("2026-12-30T21:00:00-05:00")!, opponent: "球队", isHome: false, points: 100, opponentPoints: 99)
        let schedule = NBAPregamePreview.Schedule(teamID: "13", scope: scope, games: [first])
        #expect(preview.teams(schedules: ["13": schedule])[0].offDays == 0)
        #expect(NBASchedulePolicy.startDate("2026-12-31T10:00:00+08:00") == first.date)
    }

    @Test func cancellationsPostponementAndUnknownSeasonKeepClearLocalStates() throws {
        for (name, expected) in [("STATUS_POSTPONED", "比赛已延期"), ("STATUS_CANCELED", "比赛已取消"), ("STATUS_DELAYED", "开赛时间延后")] {
            var object = try pregameObject(); var header = object["header"] as! [String: Any]
            var matches = header["competitions"] as! [[String: Any]]
            matches[0]["status"] = ["type": ["name": name, "state": "pre", "completed": false]]
            header["competitions"] = matches; header["season"] = ["year": 2028, "type": 2]; object["header"] = header
            let preview = try pregameDecode(object)
            #expect(preview.specialStatus == expected)
            #expect(preview.teams().count == 2)
            #expect(preview.officialReportURL == nil)
        }
    }
}

private final class PregameCacheClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}
private actor PregameScheduleSource {
    private var count = 0
    private var fails = false
    func fail() { fails = true }
    func requests() -> Int { count }
    func fetch(_ url: URL) async throws -> Data {
        count += 1
        try await Task.sleep(nanoseconds: 10_000_000)
        if fails { throw URLError(.notConnectedToInternet) }
        return try pregameFixture(url.path.contains("/13/") ? "lakers-schedule" : "warriors-schedule")
    }
}
struct NBAPregameScheduleCacheTests {
    @Test func onlyNeededTeamRequestsCoalesceWarmRestartAndFailedRefreshPreservesDate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = PregameScheduleSource(); let clock = PregameCacheClock()
        let scope = NBAPregamePreview.Scope(year: 2027, stage: 2)
        let store = NBAPregameScheduleStore(directory: directory, now: { clock.now() }, fetch: { try await source.fetch($0) })
        async let first = store.load(teamID: "13", scope: scope)
        async let same = store.load(teamID: "13", scope: scope)
        let pair = try await (first, same)
        #expect(pair.0.schedule.games.count == 5 && pair.1.schedule.games.count == 5)
        #expect(await source.requests() == 1)
        _ = try await store.load(teamID: "9", scope: scope)
        #expect(await source.requests() == 2)
        let restarted = NBAPregameScheduleStore(directory: directory, now: { clock.now() }, fetch: { try await source.fetch($0) })
        #expect(try await restarted.load(teamID: "13", scope: scope).date == pair.0.date)
        #expect(await source.requests() == 2)
        clock.advance(NBAPregameScheduleStore.ttl); await source.fail()
        let failed = try await store.load(teamID: "13", scope: scope)
        #expect(failed.refreshFailed && failed.isStale)
        #expect(failed.date == pair.0.date && failed.schedule == pair.0.schedule)
        let count = await source.requests()
        _ = try await store.load(teamID: "13", scope: scope)
        #expect(await source.requests() == count)
    }
}
