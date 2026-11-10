import Foundation
import CoreGraphics

/// Immutable, already decoded pixels. The lock protects the LRU, so a View can
/// look up its initial image synchronously without disk I/O or an actor hop.
final class NBAAvatarImageMemory: @unchecked Sendable {
    struct Value { let image: CGImage; let date: Date }
    private struct Item { let value: Value; let cost: Int; var access: UInt64 }
    private let lock = NSLock()
    private var items: [URL: Item] = [:]
    private var tick: UInt64 = 0
    private var bytes = 0
    let costLimit: Int
    let countLimit: Int
    private var pressure: DispatchSourceMemoryPressure?

    init(costLimit: Int = 48 * 1024 * 1024, countLimit: Int = 600) {
        self.costLimit = costLimit; self.countLimit = countLimit
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in self?.removeAll() }
        source.resume()
        pressure = source
    }

    deinit { pressure?.cancel() }

    func value(for url: URL) -> Value? {
        lock.withLock {
            guard var item = items[url] else { return nil }
            tick &+= 1; item.access = tick; items[url] = item
            return item.value
        }
    }

    func insert(_ image: CGImage, date: Date, for url: URL) {
        let cost = image.bytesPerRow * image.height
        lock.withLock {
            if let old = items.removeValue(forKey: url) { bytes -= old.cost }
            guard cost <= costLimit, countLimit > 0 else { return }
            while bytes + cost > costLimit || items.count >= countLimit {
                guard let key = items.min(by: { $0.value.access < $1.value.access })?.key,
                      let removed = items.removeValue(forKey: key) else { break }
                bytes -= removed.cost
            }
            tick &+= 1
            items[url] = Item(value: Value(image: image, date: date), cost: cost, access: tick)
            bytes += cost
        }
    }

    func remove(_ url: URL) {
        lock.withLock { if let old = items.removeValue(forKey: url) { bytes -= old.cost } }
    }
    func removeAll() { lock.withLock { items.removeAll(); bytes = 0 } }
    var usage: (count: Int, bytes: Int) { lock.withLock { (items.count, bytes) } }
}

extension Notification.Name { static let nbaAvatarPrepared = Notification.Name("NBAAvatarPrepared") }
