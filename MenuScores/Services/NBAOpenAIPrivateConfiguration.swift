import Foundation
import Darwin

/// User-approved local plaintext storage. Never bundled, logged or sent as
/// content. Normal reads have no Keychain fallback; legacy access is migration
/// only. Diagnostics contain counters, never credential values or fragments.
final class NBAOpenAIPrivateConfiguration: @unchecked Sendable {
    static let shared = NBAOpenAIPrivateConfiguration(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MenuScores/PrivateConfiguration"))
    struct Configuration: Codable { let version: Int; let apiKey: String }
    struct Diagnostics: Codable {
        let processID = ProcessInfo.processInfo.processIdentifier
        var privateFileReads = 0, legacyMigrationReads = 0, migrationsCompleted = 0
        var lastMigrationStatus: Int32?
        var updatedAt = Date()
        let provider = "local_plaintext_file"
    }
    enum Failure: Error, LocalizedError {
        case missing, invalid, permissions, io
        var errorDescription: String? {
            switch self {
            case .missing: "本机 OpenAI 配置尚未保存。请打开安全配置迁移一次，或在隐藏输入框保存 key；正常请求不会再读取钥匙串。"
            case .invalid: "本机 OpenAI 配置无效，请在配置窗口重新保存。未回退读取钥匙串。"
            case .permissions: "本机私有配置路径或访问权限不安全，未读取凭据。请在配置窗口重新保存。"
            case .io: "本机 OpenAI 配置暂时无法读写，未读取钥匙串，也未发送模型请求。"
            }
        }
    }
    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("openai.json") }
    private var markerURL: URL { directory.appendingPathComponent("storage-mode.json") }
    var diagnosticsURL: URL { directory.appendingPathComponent("credential-access-state.json") }
    private let legacyRead: @Sendable (Bool) throws -> String?
    private let lock = NSRecursiveLock()
    private var diagnostics = Diagnostics()
    init(directory: URL, legacyRead: @escaping @Sendable (Bool) throws -> String? = { interaction in
        defer { NBAOpenAICredential.session.clear() }
        return try NBAOpenAICredential.readForAuthorizedRequest(allowInteraction: interaction)
    }) { self.directory = directory; self.legacyRead = legacyRead }
    var isConfigured: Bool { FileManager.default.fileExists(atPath: fileURL.path) }
    private func safeAttributes(_ path: URL, directory expectedDirectory: Bool) throws {
        guard let a = try? FileManager.default.attributesOfItem(atPath:path.path),
              a[.type] as? FileAttributeType == (expectedDirectory ? .typeDirectory : .typeRegular),
              (a[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let mode = (a[.posixPermissions] as? NSNumber)?.intValue, mode & 0o077 == 0 else { throw Failure.permissions }
    }
    private func prepareDirectory() throws {
        do {
            if !FileManager.default.fileExists(atPath:directory.path) {
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            }
            try safeAttributes(directory,directory:true)
        } catch let failure as Failure { throw failure } catch { throw Failure.io }
    }
    func readForAuthorizedRequest() throws -> String? {
        lock.lock();defer { lock.unlock() }
        diagnostics.privateFileReads += 1;recordDiagnostics()
        guard isConfigured else { throw Failure.missing }
        try safeAttributes(directory,directory:true)
        let fd = open(fileURL.path,O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.io }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= 4096 else { throw Failure.permissions }
        let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:false)
        guard let data = try? handle.read(upToCount:4097), data.count <= 4096,
              let config = try? JSONDecoder().decode(Configuration.self,from:data),config.version == 1,Self.valid(config.apiKey) else { throw Failure.invalid }
        return config.apiKey
    }
    private static func valid(_ value: String) -> Bool {
        (16...512).contains(value.utf8.count) && value.unicodeScalars.allSatisfy { (33...126).contains($0.value) }
    }
    private func atomicWrite(_ data: Data, to path: URL) throws {
        let temporary = directory.appendingPathComponent(".configuration-" + UUID().uuidString)
        let fd = open(temporary.path,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard fd >= 0 else { throw Failure.io }
        defer { close(fd); unlink(temporary.path) }
        let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:false)
        do {
            try handle.write(contentsOf:data)
            guard fsync(fd) == 0 else { throw Failure.io }
            guard rename(temporary.path,path.path) == 0 else { throw Failure.io }
        } catch { throw Failure.io }
    }
    private func writeMarker() throws {
        let data = Data(#"{"version":1,"mode":"local_plaintext_file","legacyMigrationAttempted":true}"#.utf8)
        try atomicWrite(data,to:markerURL)
    }
    func save(_ value: String) throws {
        lock.lock();defer { lock.unlock() }
        let key = value.trimmingCharacters(in:.whitespacesAndNewlines)
        guard Self.valid(key) else { throw Failure.invalid }
        try prepareDirectory()
        if isConfigured { try safeAttributes(fileURL,directory:false) }
        try atomicWrite(JSONEncoder().encode(Configuration(version:1,apiKey:key)),to:fileURL)
        try writeMarker();recordDiagnostics()
    }
    /// One bounded, non-interactive upgrade attempt. After mode selection,
    /// absent/invalid files never silently revive a Keychain dependency.
    func prepareForUse() throws -> Bool {
        lock.lock();defer { lock.unlock() }
        if isConfigured { _ = try readForAuthorizedRequest();return true }
        try prepareDirectory()
        if FileManager.default.fileExists(atPath:markerURL.path) { recordDiagnostics();return false }
        try writeMarker()
        return try migrateLegacy(allowInteraction:false)
    }
    func migrateLegacy(allowInteraction: Bool) throws -> Bool {
        lock.lock();defer { lock.unlock() }
        if isConfigured { _ = try readForAuthorizedRequest();return true }
        try prepareDirectory();try writeMarker()
        diagnostics.legacyMigrationReads += 1
        do {
            guard let value = try legacyRead(allowInteraction) else { recordDiagnostics();return false }
            try save(value);diagnostics.migrationsCompleted += 1;diagnostics.lastMigrationStatus = 0;recordDiagnostics();return true
        } catch {
            diagnostics.lastMigrationStatus = (error as? NBAOpenAICredential.Failure)?.status
            recordDiagnostics();throw error
        }
    }
    /// Only the user's explicit Delete button removes the new file. The old
    /// Keychain item is never deleted; the marker prevents automatic fallback.
    func removeLocalConfiguration() throws {
        lock.lock();defer { lock.unlock() }
        try prepareDirectory()
        if isConfigured {
            try safeAttributes(fileURL,directory:false)
            do { try FileManager.default.removeItem(at:fileURL) } catch { throw Failure.io }
        }
        try writeMarker();recordDiagnostics()
    }
    func diagnosticSnapshot() -> Diagnostics { lock.lock();defer { lock.unlock() };return diagnostics }
    private func recordDiagnostics() {
        diagnostics.updatedAt = Date()
        guard (try? safeAttributes(directory,directory:true)) != nil, let data = try? JSONEncoder().encode(diagnostics) else { return }
        try? atomicWrite(data,to:diagnosticsURL)
    }
}
