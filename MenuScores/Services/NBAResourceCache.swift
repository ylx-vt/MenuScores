import Foundation

/// Raw response cache shared by the NBA stores. A view cancelling its wait does
/// not cancel a download another view is using. Only successful validation
/// replaces the stored response or its original fetch date.
actor NBAResourceCache {
    struct Entry { let data: Data; let date: Date; let revision = UUID() }
    struct Result { let entry: Entry; let refreshFailed: Bool }
    typealias Clock = @Sendable () -> Date
    typealias Validator = @Sendable (String, Data) throws -> Void
    private let directory: URL
    private let now: Clock
    private let validate: Validator
    private let storedDate: @Sendable (Data) -> Date?
    private var memory: [String: Entry] = [:]
    private var diskRead: Set<String> = []
    private var pending: [String: Task<Result, Error>] = [:]
    private var retryAfter: [String: Date] = [:]
    private var failures: [String: Error] = [:]

    init(directory: URL, now: @escaping Clock = { Date() },
         storedDate: @escaping @Sendable (Data) -> Date? = { _ in nil },
         validate: @escaping Validator) {
        self.directory = directory; self.now = now
        self.storedDate = storedDate; self.validate = validate
    }

    private func file(_ key: String) -> URL {
        directory.appendingPathComponent(key + ".json")
    }

    func cached(_ key: String) -> Result? {
        guard key.range(of: "^[0-9A-Za-z_-]+$", options: .regularExpression) != nil else { return nil }
        if memory[key] == nil, diskRead.insert(key).inserted,
           let data = try? Data(contentsOf: file(key)),
           (try? validate(key, data)) != nil,
           let modified = (try? file(key).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            memory[key] = Entry(data: data, date: storedDate(data) ?? modified)
        }
        return memory[key].map { Result(entry: $0, refreshFailed: retryAfter[key] != nil) }
    }

    func load(_ key: String, ttl: TimeInterval, force: Bool = false,
              fetch: @escaping @Sendable () async throws -> Data) async throws -> Result {
        guard key.range(of: "^[0-9A-Za-z_-]+$", options: .regularExpression) != nil else { throw URLError(.badURL) }
        let old = cached(key)
        if !force, let old, now().timeIntervalSince(old.entry.date) < ttl { return old }
        if let task = pending[key] { return try await task.value }
        if !force, let retry = retryAfter[key], retry > now(), let old {
            return Result(entry: old.entry, refreshFailed: true)
        }
        if !force, let retry = retryAfter[key], retry > now(), let error = failures[key] { throw error }
        let task = Task { try await self.refresh(key, old: old?.entry, fetch: fetch) }
        pending[key] = task
        return try await task.value
    }

    private func refresh(_ key: String, old: Entry?,
                         fetch: @escaping @Sendable () async throws -> Data) async throws -> Result {
        defer { pending[key] = nil }
        do {
            let data = try await fetch()
            try validate(key, data)
            let entry = Entry(data: data, date: storedDate(data) ?? now())
            memory[key] = entry
            retryAfter[key] = nil
            failures[key] = nil
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                try data.write(to: file(key), options: .atomic)
                try FileManager.default.setAttributes([.modificationDate: entry.date], ofItemAtPath: file(key).path)
            } catch { /* Memory remains usable when disk storage is unavailable. */ }
            return Result(entry: entry, refreshFailed: false)
        } catch {
            retryAfter[key] = now().addingTimeInterval(60)
            failures[key] = error
            if let old { return Result(entry: old, refreshFailed: true) }
            throw error
        }
    }
}
