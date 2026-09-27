import SwiftUI
import UIKit

// Adapted from Sodalite Components/AsyncCachedImage.swift: memory-cached, decoded off the main
// actor, the placeholder held until the image is opaque. Selenite's images come from a loader (box
// art over the pinned HTTPS client, which a URL-based AsyncImage cannot use) instead of a URL.

struct AsyncCachedImage<Content: View, Placeholder: View>: View {
    let key: String
    let load: @MainActor () async -> Data?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var loaded: UIImage?

    var body: some View {
        ZStack {
            if let loaded {
                content(Image(uiImage: loaded))
                    .transition(.opacity.animation(.easeIn(duration: 0.25)))
                    .zIndex(1)
            } else {
                // Stays opaque until the image above it is, so nothing flashes through between them.
                placeholder()
                    .transition(.opacity.animation(.easeOut(duration: 0.2).delay(0.25)))
                    .zIndex(0)
            }
        }
        .task(id: key) { await fetch() }
    }

    private func fetch() async {
        if let cached = ImageCache.shared.image(for: key) {
            loaded = cached
            return
        }
        loaded = nil
        guard let data = await load(), let image = await ImageCache.decode(data) else { return }
        ImageCache.shared.store(image, for: key)
        guard !Task.isCancelled else { return }
        loaded = image
    }
}

/// Decoded images by key, bounded by decoded byte size. NSCache is thread-safe.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.totalCostLimit = 150_000_000
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, for key: String) {
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        cache.setObject(image, forKey: key as NSString, cost: Int(pixels) * 4)
    }

    /// Decode and force-decompress off the main actor, so the first draw is not a dropped frame.
    /// Here rather than on the generic view, whose View conformances are main-actor isolated.
    static func decode(_ data: Data) async -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
    }
}
