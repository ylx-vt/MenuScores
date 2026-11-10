import SwiftUI

struct NBACachedAvatar: View {
    let url: String?
    let tint: Color
    private let cache: NBAAvatarCache
    @State private var image: CGImage?

    init(url: String?, tint: Color, cache: NBAAvatarCache = .shared) {
        self.url = url; self.tint = tint; self.cache = cache
        _image = State(initialValue: url.flatMap(URL.init(string:)).flatMap { cache.cachedImage(for: $0) })
    }

    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
            else { Image(systemName: "person.fill").foregroundStyle(tint.opacity(0.7)) }
        }
        .frame(width: 24, height: 24)
        .background(tint.opacity(0.08), in: Circle()).clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url, let address = URL(string: url) else { image = nil; return }
            image = cache.cachedImage(for: address)
            let prepared = await cache.image(for: address)
            guard !Task.isCancelled else { return }
            if let prepared { image = prepared }
        }
        .onReceive(NotificationCenter.default.publisher(for: .nbaAvatarPrepared)
            .filter { ($0.object as? URL)?.absoluteString == url }.receive(on: DispatchQueue.main)) { _ in
                if let address = url.flatMap(URL.init(string:)) { image = cache.cachedImage(for: address) }
            }
    }
}
