import Foundation
import ImageIO

actor NBAAvatarCache {
    static let shared: NBAAvatarCache = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--terra-native-qa") || ProcessInfo.processInfo.arguments.contains("--review-qa") {
            let root = URL(fileURLWithPath: "/tmp/MenuScores-build/TerraDemo/real/qa", isDirectory: true)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [NBATerraQAOffline.self]
            return NBAAvatarCache(directory: root.appendingPathComponent("avatars"), thumbnailDirectory: root.appendingPathComponent("thumbnails"),
                                  session: URLSession(configuration: configuration), seedURL: nil)
        }
        if AppRuntime.isRestorationPreview {
            let root = NBARestorationOffline.directory
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [NBARestorationOffline.self]
            return NBAAvatarCache(directory: root.appendingPathComponent("avatars"),
                thumbnailDirectory: root.appendingPathComponent("thumbnails"),
                session: URLSession(configuration: configuration), seedURL: nil)
        }
        #endif
        return NBAAvatarCache()
    }()
    enum Priority: Int, Sendable { case visible, pinned, menu, background }
    struct Portrait: Codable, Sendable {
        let id: String
        let url: URL
        var teamID: String?
        init(id: String, url: URL, teamID: String? = nil) { self.id = id; self.url = url; self.teamID = teamID }
    }
    struct Metrics {
        let active: Int; let queued: Int; let memoryCount: Int; let memoryBytes: Int
        let diskCount: Int; let diskBytes: Int; let leagueCount: Int; let leagueReady: Int
    }
    private struct Record: Codable {
        var portrait: Portrait
        var lastUsed: Date = .distantPast
        var retryAfter: Date?
    }
    private struct Index: Codable {
        var records: [String: Record] = [:]
        var leagueIDs: Set<String> = []
        var season: Int?
    }
    private struct Seed: Decodable { let season: Int; let portraits: [Portrait] }
    private struct DiskFile { var bytes: Int; var access: Date }
    private struct Loaded { var index: Index; var disk: [String: DiskFile]; var originals: Set<String> }
    private struct Job {
        var priority: Priority
        let order: UInt64
        var forceNetwork: Bool
        var persistOriginal: Bool
        var waiters: [CheckedContinuation<NBAAvatarPixels?, Never>] = []
    }
    nonisolated let images: NBAAvatarImageMemory
    private let directory: URL
    private let thumbnails: URL
    private let seedURL: URL?
    private let session: URLSession
    private let now: @Sendable () -> Date
    private let diskByteLimit: Int
    private let diskCountLimit: Int
    private let rawMemory = NSCache<NSURL, NSData>()
    private var index = Index()
    private var disk: [String: DiskFile] = [:]
    private var loading: Task<Loaded, Never>?
    private var loaded = false
    private var jobs: [URL: Job] = [:]
    private var active: Set<URL> = []
    private var localActive: Set<URL> = []
    private var originalKeys: Set<String> = []
    private var fileKeys: [URL: String] = [:]
    private var sequence: UInt64 = 0
    private var paused = false
    private var transportFailures = 0
    private var backgroundRetry: Date?
    private var retryTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    private static let ttl: TimeInterval = 7 * 24 * 60 * 60

    init(directory: URL? = nil, thumbnailDirectory: URL? = nil, session: URLSession = .shared,
         seedURL: URL? = Bundle.main.url(forResource: "NBAAvatarSeed", withExtension: "json"),
         now: @escaping @Sendable () -> Date = { Date() }, images: NBAAvatarImageMemory = NBAAvatarImageMemory(),
         diskByteLimit: Int = 32 * 1024 * 1024, diskCountLimit: Int = 1000) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? caches.appendingPathComponent("NBAAvatars", isDirectory: true)
        self.thumbnails = thumbnailDirectory ?? directory?.appendingPathComponent("thumbnails", isDirectory: true)
            ?? caches.appendingPathComponent("NBAAvatarThumbnails-v1", isDirectory: true)
        self.session = session; self.seedURL = seedURL; self.now = now; self.images = images
        self.diskByteLimit = diskByteLimit; self.diskCountLimit = diskCountLimit
        rawMemory.countLimit = 24; rawMemory.totalCostLimit = 4 * 1024 * 1024
    }
    nonisolated func cachedImage(for url: URL) -> CGImage? { images.value(for: url)?.image }
    private static func valid(_ url: URL) -> Bool { url.scheme == "https" && url.host == "a.espncdn.com" }

    private func ensureLoaded() async {
        guard !loaded else { return }
        if loading == nil {
            let thumbnails = thumbnails; let seedURL = seedURL; let originals = directory
            loading = Task.detached(priority: .utility) {
                var index = (try? Data(contentsOf: thumbnails.appendingPathComponent("index.json")))
                    .flatMap { try? JSONDecoder().decode(Index.self, from: $0) } ?? Index()
                if let seedURL, let data = try? Data(contentsOf: seedURL), let seed = try? JSONDecoder().decode(Seed.self, from: data),
                   index.season == nil || index.season == seed.season {
                    let bootstrap = index.leagueIDs.isEmpty
                    index.season = seed.season
                    for portrait in seed.portraits where Self.valid(portrait.url) {
                        if index.records[portrait.id] == nil { index.records[portrait.id] = Record(portrait: portrait) }
                        if bootstrap { index.leagueIDs.insert(portrait.id) }
                    }
                }
                var disk: [String: DiskFile] = [:]
                let files = (try? FileManager.default.contentsOfDirectory(at: thumbnails, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
                for file in files where file.pathExtension == "png" && file.deletingPathExtension().lastPathComponent.count == 64 {
                    let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    disk[file.lastPathComponent] = DiskFile(bytes: values?.fileSize ?? 0, access: values?.contentModificationDate ?? .distantPast)
                }
                for record in index.records.values {
                    let name = NBAAvatarDisk.key(record.portrait.url) + ".png"
                    if var entry = disk[name] { entry.access = max(entry.access, record.lastUsed); disk[name] = entry }
                }
                let legacy = (try? FileManager.default.contentsOfDirectory(at: originals, includingPropertiesForKeys: nil)) ?? []
                return Loaded(index: index, disk: disk, originals: Set(legacy.filter { $0.pathExtension == "image" }.map { $0.deletingPathExtension().lastPathComponent }))
            }
        }
        let value = await loading!.value
        guard !loaded else { return }
        index = value.index; disk = value.disk; originalKeys = value.originals; loaded = true; loading = nil
        pruneDisk()
    }
    // App-lifetime bootstrap; enqueueing never waits for the 425 downloads.
    func prepareLeague(priorityTeams: Set<String> = []) async {
        await ensureLoaded()
        let recent = index.records.values.sorted { $0.lastUsed > $1.lastUsed }.filter { $0.lastUsed != .distantPast }.prefix(64)
        for record in recent { enqueue(record.portrait.url, priority: .menu) }
        for record in index.records.values.sorted(by: { $0.portrait.id < $1.portrait.id }) where index.leagueIDs.contains(record.portrait.id) {
            enqueue(record.portrait.url, priority: record.portrait.teamID.map(priorityTeams.contains) == true ? .pinned : .background)
        }
        schedulePersist()
    }
    // Receives metadata from an already requested league response, never profiles.
    func register(_ portraits: [Portrait], season: Int? = nil) async {
        await ensureLoaded()
        let currentSeason = season.map { index.season == nil || $0 >= index.season! } ?? false
        if let season, currentSeason { index.season = season; index.leagueIDs = Set(portraits.map(\.id)) }
        for portrait in portraits where Self.valid(portrait.url) {
            if season != nil && !currentSeason && index.records[portrait.id] != nil { continue }
            if let old = index.records[portrait.id], old.portrait.url != portrait.url {
                images.remove(old.portrait.url)
                index.records[portrait.id] = Record(portrait: portrait, lastUsed: old.lastUsed)
            } else if var old = index.records[portrait.id] {
                old.portrait = portrait; index.records[portrait.id] = old
            } else { index.records[portrait.id] = Record(portrait: portrait) }
        }
        if currentSeason {
            for portrait in portraits { enqueue(portrait.url, priority: .background) }
        }
        schedulePersist()
    }
    func prioritizeTeams(_ teamIDs: Set<String>, priority: Priority = .pinned) async {
        await ensureLoaded()
        let portraits = index.records.values.filter { $0.portrait.teamID.map(teamIDs.contains) == true }.map(\.portrait)
        for portrait in portraits { enqueue(portrait.url, priority: priority) }
    }
    func image(for url: URL, priority: Priority = .visible) async -> CGImage? {
        guard Self.valid(url) else { return nil }
        await ensureLoaded(); touch(url, priority: priority)
        if let cached = images.value(for: url) {
            if now().timeIntervalSince(cached.date) >= Self.ttl { enqueue(url, priority: .background, forceNetwork: true) }
            return cached.image
        }
        return await request(url, priority: priority)?.image
    }
    // Original-byte compatibility. Display and batch preparation use image(for:),
    // and never persist newly downloaded full-size source files.
    func data(for url: URL) async -> Data? {
        guard Self.valid(url) else { return nil }
        await ensureLoaded()
        if let cached = rawMemory.object(forKey: url as NSURL) { return cached as Data }
        let original = directory.appendingPathComponent(key(url) + ".image")
        if let data = try? Data(contentsOf: original), NBAAvatarDisk.decode(data) != nil {
            rawMemory.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
            if now().timeIntervalSince(NBAAvatarDisk.modified(original)) >= Self.ttl { enqueue(url, priority: .background, forceNetwork: true) }
            return data
        }
        let value = await request(url, priority: .visible, forceNetwork: FileManager.default.fileExists(atPath: original.path), persistOriginal: true)
        return value?.sourceData ?? value?.thumbnailData
    }
    func prewarm(_ urls: [URL], priority: Priority = .menu) async {
        var seen: Set<URL> = []
        let ordered = urls.filter { seen.insert($0).inserted }
        await withTaskGroup(of: Void.self) { group in
            for url in ordered { group.addTask { _ = await self.image(for: url, priority: priority) } }
        }
    }
    func prewarmGame(_ gameID: String) async {
        guard let cached = await NBABoxScoreStore.shared.cached(gameID: gameID) else { return }
        await prewarm(cached.summary.teams.flatMap(\.rows).compactMap { $0.headshot.flatMap(URL.init(string:)) }, priority: .pinned)
    }
    func prewarmTeam(_ teamID: String) async { await prioritizeTeams([teamID]) }
    func setBackgroundPaused(_ value: Bool) { paused = value; pump() }
    func trimMemory() { images.removeAll(); rawMemory.removeAllObjects() }

    private func touch(_ url: URL, priority: Priority) {
        if let key = index.records.first(where: { $0.value.portrait.url == url })?.key {
            if priority != .background { index.records[key]?.lastUsed = now() }
        } else {
            let id = url.deletingPathExtension().lastPathComponent
            if index.records[id] == nil { index.records[id] = Record(portrait: Portrait(id: id, url: url), lastUsed: priority == .background ? .distantPast : now()) }
        }
        if priority != .background { disk[key(url) + ".png"]?.access = now() }
    }
    private func retryAfter(_ url: URL) -> Date? { index.records.values.first(where: { $0.portrait.url == url })?.retryAfter }
    private func key(_ url: URL) -> String {
        if let value = fileKeys[url] { return value }
        let value = NBAAvatarDisk.key(url); fileKeys[url] = value; return value
    }
    private func mayReadLocal(_ url: URL) -> Bool {
        disk[key(url) + ".png"] != nil || originalKeys.contains(key(url))
    }
    private func request(_ url: URL, priority: Priority, forceNetwork: Bool = false, persistOriginal: Bool = false) async -> NBAAvatarPixels? {
        if let retry = retryAfter(url), retry > now(), forceNetwork || !mayReadLocal(url) { return nil }
        return await withCheckedContinuation { enqueue(url, priority: priority, forceNetwork: forceNetwork, persistOriginal: persistOriginal, waiter: $0) }
    }
    private func enqueue(_ url: URL, priority: Priority, forceNetwork: Bool = false, persistOriginal: Bool = false, waiter: CheckedContinuation<NBAAvatarPixels?, Never>? = nil) {
        guard Self.valid(url), !(retryAfter(url).map { $0 > now() && (forceNetwork || !mayReadLocal(url)) } ?? false) else { waiter?.resume(returning: nil); return }
        if !forceNetwork, waiter == nil, let cached = images.value(for: url), now().timeIntervalSince(cached.date) < Self.ttl { return }
        touch(url, priority: priority)
        if var job = jobs[url] {
            if priority.rawValue < job.priority.rawValue { job.priority = priority }
            job.persistOriginal = job.persistOriginal || persistOriginal
            if !active.contains(url) { job.forceNetwork = job.forceNetwork || forceNetwork }
            if let waiter { job.waiters.append(waiter) }; jobs[url] = job
        } else {
            sequence &+= 1
            var job = Job(priority: priority, order: sequence, forceNetwork: forceNetwork, persistOriginal: persistOriginal)
            if let waiter { job.waiters.append(waiter) }; jobs[url] = job
        }
        pump()
    }
    private func pump() {
        // One local decode lane stays available even while two slow downloads
        // are in progress. A corrupt local entry is requeued for network, never
        // allowed to turn this lane into a third concurrent download.
        while localActive.count < 1, let url = next(local: true) { start(url, local: true) }
        while active.count - localActive.count < 2, let url = next(local: false) { start(url, local: false) }
    }
    private func next(local: Bool) -> URL? {
        jobs.filter { url, job in
            guard !active.contains(url), (mayReadLocal(url) && !job.forceNetwork) == local else { return false }
            return local || job.priority != .background || (!paused && (backgroundRetry == nil || backgroundRetry! <= now()))
        }.min { a, b in a.value.priority == b.value.priority ? a.value.order < b.value.order : a.value.priority.rawValue < b.value.priority.rawValue }?.key
    }
    private func start(_ url: URL, local: Bool) {
        guard let job = jobs[url] else { return }
        active.insert(url); if local { localActive.insert(url) }
        let originals = directory; let thumbnails = thumbnails; let session = session; let now = now
        let allowNetwork = !local && !(retryAfter(url).map { $0 > now() } ?? false)
        Task.detached(priority: job.priority == .visible ? .userInitiated : .utility) {
            let (value, failed) = await NBAAvatarDisk.load(url: url, originals: originals, thumbnails: thumbnails,
                session: session, forceNetwork: job.forceNetwork, allowNetwork: allowNetwork, now: now)
            await self.finished(url, value: value, transportFailure: failed)
        }
    }
    private func finished(_ url: URL, value: NBAAvatarPixels?, transportFailure: Bool) {
        guard var job = jobs.removeValue(forKey: url) else { return }; active.remove(url)
        let local = localActive.remove(url) != nil
        if local && value == nil {
            originalKeys.remove(key(url)); disk[key(url) + ".png"] = nil
            job.forceNetwork = true; jobs[url] = job; pump(); return
        }
        let ids = index.records.filter { $0.value.portrait.url == url }.map(\.key)
        if let value {
            transportFailures = 0; images.insert(value.image, date: value.sourceDate, for: url)
            if value.downloaded { for id in ids { index.records[id]?.retryAfter = nil } }
            NotificationCenter.default.post(name: .nbaAvatarPrepared, object: url)
            if job.persistOriginal, let data = value.sourceData {
                NBAAvatarDisk.write(data, to: directory.appendingPathComponent(key(url) + ".image"), date: value.sourceDate)
                originalKeys.insert(key(url))
                rawMemory.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
            }
            let file = thumbnails.appendingPathComponent(key(url) + ".png")
            if FileManager.default.fileExists(atPath: file.path) { disk[file.lastPathComponent] = DiskFile(bytes: value.thumbnailData.count, access: job.priority == .background ? value.sourceDate : now()) }
        } else {
            for id in ids { index.records[id]?.retryAfter = now().addingTimeInterval(60) }
            if transportFailure { transportFailures += 1 }
            if transportFailures >= 3 {
                backgroundRetry = now().addingTimeInterval(60)
                if retryTask == nil { retryTask = Task { try? await Task.sleep(nanoseconds: 60_000_000_000); self.resumeBackground() } }
            }
        }
        for waiter in job.waiters { waiter.resume(returning: value) }
        pruneDisk(); schedulePersist()
        if let value, now().timeIntervalSince(value.sourceDate) >= Self.ttl, !job.forceNetwork { enqueue(url, priority: .background, forceNetwork: true) }
        pump()
    }
    private func resumeBackground() { retryTask = nil; backgroundRetry = nil; transportFailures = 0; pump() }
    private func pruneDisk() {
        var bytes = disk.values.reduce(0) { $0 + $1.bytes }
        for (name, entry) in disk.sorted(by: { $0.value.access < $1.value.access }) {
            guard bytes > diskByteLimit || disk.count > diskCountLimit else { break }
            if active.contains(where: { key($0) + ".png" == name }) { continue }
            try? FileManager.default.removeItem(at: thumbnails.appendingPathComponent(name)); disk[name] = nil; bytes -= entry.bytes
        }
    }
    private func schedulePersist() {
        guard persistTask == nil else { return }
        persistTask = Task { do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }; self.persistNow() }
    }
    private func persistNow() {
        persistTask = nil
        if index.records.count > 1500 {
            let stale = index.records.filter { !index.leagueIDs.contains($0.key) }.sorted { $0.value.lastUsed < $1.value.lastUsed }
            for (id, _) in stale.prefix(index.records.count - 1500) { index.records[id] = nil }
        }
        if fileKeys.count > 1600 {
            let retained = Set(index.records.values.map { $0.portrait.url }).union(active)
            fileKeys = fileKeys.filter { retained.contains($0.key) }
        }
        if let data = try? JSONEncoder().encode(index) { NBAAvatarDisk.write(data, to: thumbnails.appendingPathComponent("index.json"), date: now()) }
    }
    func flush() { persistTask?.cancel(); persistTask = nil; persistNow() }
    func metrics() async -> Metrics {
        await ensureLoaded(); let memory = images.usage
        return Metrics(active: active.count, queued: jobs.count - active.count, memoryCount: memory.count, memoryBytes: memory.bytes,
            diskCount: disk.count, diskBytes: disk.values.reduce(0) { $0 + $1.bytes }, leagueCount: index.leagueIDs.count,
            leagueReady: index.leagueIDs.filter { id in index.records[id].map { disk[key($0.portrait.url) + ".png"] != nil } ?? false }.count)
    }
}
