import CoreGraphics
import Foundation

/// Bounded cache of fully-composited character artwork for interactive use.
///
/// Character placement, movement, depth, rotation, and shadows stay dynamic;
/// only the body/face/outfit stack is flattened. That turns several large
/// alpha-blended image draws per character into one draw on steady frames.
public final class CharacterSpriteCache: @unchecked Sendable {
    public let pixelSize: Int
    private let capacity: Int
    private let lock = NSLock()
    private var entries: [(key: String, image: CGImage)] = []

    public init(pixelSize: Int = 800, capacity: Int = 32) {
        self.pixelSize = max(1, pixelSize)
        self.capacity = max(1, capacity)
    }

    var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    func image(for key: String, build: () -> CGImage?) -> CGImage? {
        lock.lock()
        if let index = entries.firstIndex(where: { $0.key == key }) {
            let hit = entries.remove(at: index)
            entries.insert(hit, at: 0)
            lock.unlock()
            return hit.image
        }
        lock.unlock()

        guard let image = build() else { return nil }
        lock.lock()
        // Another renderer may have populated the same entry while this one
        // was rasterizing. Keep the first image and avoid duplicate storage.
        if let index = entries.firstIndex(where: { $0.key == key }) {
            let hit = entries.remove(at: index)
            entries.insert(hit, at: 0)
            lock.unlock()
            return hit.image
        }
        entries.insert((key, image), at: 0)
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
        lock.unlock()
        return image
    }
}
