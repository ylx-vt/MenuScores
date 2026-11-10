import Foundation

/// The product's schedule day is always Beijing time, independent of the Mac.
enum NBASchedulePolicy {
    static let timeZone = TimeZone(identifier: "Asia/Shanghai")!
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = timeZone
        return value
    }

    struct Window: Equatable {
        let today: DateInterval
        let tomorrow: DateInterval?
        let nextTransition: Date
    }

    static func window(now: Date = Date()) -> Window {
        let calendar = calendar
        let start = calendar.startOfDay(for: now)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: start)!
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: start)!
        let tomorrow = now >= noon
            ? DateInterval(start: nextDay, end: calendar.date(byAdding: .day, value: 1, to: nextDay)!) : nil
        return Window(today: DateInterval(start: start, end: nextDay), tomorrow: tomorrow,
                      nextTransition: now < noon ? noon : nextDay)
    }

    static func startDate(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }
        iso.formatOptions.insert(.withFractionalSeconds)
        if let date = iso.date(from: text) { return date }
        let short = DateFormatter()
        short.locale = Locale(identifier: "en_US_POSIX")
        short.timeZone = timeZone
        short.dateFormat = "yyyy-MM-dd'T'HH:mmXXXXX"
        return short.date(from: text)
    }

    static func contains(_ date: Date, in interval: DateInterval) -> Bool {
        // DateInterval.contains includes its end; schedule days must not overlap.
        date >= interval.start && date < interval.end
    }

    struct Groups {
        let today: [Event]
        let tomorrow: [Event]
    }

    static func groups(_ events: [Event], now: Date = Date()) -> Groups {
        let window = window(now: now)
        var seen: Set<String> = []
        let unique = events.filter { seen.insert($0.id).inserted }
        let today = unique.filter { event in
            // Keep a late game or overtime even when its start was yesterday.
            event.status.type.state == "in" || startDate(event.date).map { contains($0, in: window.today) } == true
        }
        let todayIDs = Set(today.map(\.id))
        let tomorrow = unique.filter { event in
            guard !todayIDs.contains(event.id), let interval = window.tomorrow,
                  let start = startDate(event.date) else { return false }
            return contains(start, in: interval)
        }
        func ordered(_ games: [Event]) -> [Event] {
            games.sorted {
                let lhs = startDate($0.date) ?? .distantFuture
                let rhs = startDate($1.date) ?? .distantFuture
                return lhs == rhs ? $0.id < $1.id : lhs < rhs
            }
        }
        return Groups(today: ordered(today), tomorrow: ordered(tomorrow))
    }

    static func startTime(_ date: Date, includeDay: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = includeDay ? "M月d日 HH:mm" : "HH:mm"
        return formatter.string(from: date)
    }

    static func dayTitle(_ date: Date, weekdayOnly: Bool = false, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = weekdayOnly ? "EEEE" : calendar.component(.year, from: date) == calendar.component(.year, from: now)
            ? "M月d日" : "yyyy年M月d日"
        return formatter.string(from: date)
    }
}
