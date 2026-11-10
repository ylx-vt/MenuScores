import Foundation
import CryptoKit
import ImageIO

struct NBAAvatarPixels: @unchecked Sendable {
    let image: CGImage
    let sourceDate: Date
    let sourceData: Data?
    let thumbnailData: Data
    var downloaded = false
}

enum NBAAvatarDisk {
    static let pixelSize = 160
    static func key(_ url: URL) -> String {
        let alphabet = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []; bytes.reserveCapacity(64)
        for value in SHA256.hash(data: Data(url.absoluteString.utf8)) {
            bytes.append(alphabet[Int(value >> 4)]); bytes.append(alphabet[Int(value & 15)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
    static func modified(_ file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }
    // Detached workers perform every display-path disk read and pixel decode.
    static func load(url: URL, originals: URL, thumbnails: URL, session: URLSession,
                     forceNetwork: Bool, allowNetwork: Bool, now: @escaping @Sendable () -> Date) async -> (NBAAvatarPixels?, Bool) {
        let thumbnail = thumbnails.appendingPathComponent(key(url) + ".png")
        let original = originals.appendingPathComponent(key(url) + ".image")
        if !forceNetwork, let data = try? Data(contentsOf: thumbnail), let image = decode(data) {
            return (NBAAvatarPixels(image: image, sourceDate: modified(thumbnail), sourceData: nil, thumbnailData: data), false)
        }
        if !forceNetwork, let data = try? Data(contentsOf: original), let image = decode(data), let png = png(image) {
            let date = modified(original)
            write(png, to: thumbnail, date: date)
            return (NBAAvatarPixels(image: image, sourceDate: date, sourceData: data, thumbnailData: png), false)
        }
        guard allowNetwork else { return (nil, false) }
        do {
            var request = URLRequest(url: url); request.timeoutInterval = 15
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 3 * 1024 * 1024,
                  let image = decode(data), let png = png(image) else { return (nil, false) }
            let date = now(); write(png, to: thumbnail, date: date)
            return (NBAAvatarPixels(image: image, sourceDate: date, sourceData: data, thumbnailData: png, downloaded: true), false)
        } catch {
            let transport: Set<URLError.Code> = [.notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .timedOut]
            return (nil, (error as? URLError).map { transport.contains($0.code) } ?? false)
        }
    }
    static func write(_ data: Data, to url: URL, date: Date) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        } catch { /* Prepared memory stays usable when disk storage is unavailable. */ }
    }
}
