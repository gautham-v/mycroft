import ImageIO
import SwiftUI

/// Memory-cached, downsampled remote images for list thumbnails (and anything else that wants them).
///
/// - Decoded images live in an `NSCache` keyed by URL + target pixel size, so scrolling back up a long
///   list never re-decodes. Bytes go through a dedicated `URLSession` with its own `URLCache`
///   (32 MB memory / 200 MB disk), so a relaunch doesn't refetch either.
/// - Images are decoded off the main thread with ImageIO and downsampled to the size they are shown at
///   (a 1280px YouTube `hqdefault.jpg` becomes a ~200px bitmap for a 64pt thumbnail).
/// - Concurrent requests for the same image share one download.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    /// A decoded bitmap. CGImage is immutable, so sharing it across threads is safe.
    struct Bitmap: @unchecked Sendable {
        let cgImage: CGImage
    }

    private let memory = NSCache<NSString, CGImageBox>()
    private let lock = NSLock()
    private var inFlight: [String: Task<Bitmap?, Never>] = [:]
    private let session: URLSession

    private final class CGImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    init() {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 200 << 20)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: config)
        memory.countLimit = 600
        memory.totalCostLimit = 96 << 20
    }

    private static func key(_ url: URL, _ maxPixel: Int) -> String { "\(maxPixel)|\(url.absoluteString)" }

    /// Synchronous memory-cache lookup (safe from `View.init`/`body`).
    func cached(_ url: URL, maxPixelSize: CGFloat) -> CGImage? {
        memory.object(forKey: Self.key(url, Self.bucket(maxPixelSize)) as NSString)?.image
    }

    /// Fetches, decodes and caches. Returns nil on any failure (bad status, not an image, offline).
    func image(_ url: URL, maxPixelSize: CGFloat) async -> CGImage? {
        let px = Self.bucket(maxPixelSize)
        let key = Self.key(url, px)
        if let hit = memory.object(forKey: key as NSString) { return hit.image }

        let task: Task<Bitmap?, Never> = lock.withLock {
            if let existing = inFlight[key] { return existing }
            let session = self.session
            let t = Task.detached(priority: .utility) { () -> Bitmap? in
                await Self.load(url, maxPixel: px, session: session)
            }
            inFlight[key] = t
            return t
        }
        let result = await task.value
        lock.withLock { inFlight[key] = nil }
        if let result {
            memory.setObject(CGImageBox(result.cgImage), forKey: key as NSString,
                             cost: result.cgImage.bytesPerRow * result.cgImage.height)
        }
        return result?.cgImage
    }

    /// Round up to a multiple of 64 px so near-identical sizes share an entry.
    private static func bucket(_ maxPixelSize: CGFloat) -> Int {
        let px = max(64, Int(maxPixelSize.rounded(.up)))
        return ((px + 63) / 64) * 64
    }

    private static func load(_ url: URL, maxPixel: Int, session: URLSession) async -> Bitmap? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        var request = URLRequest(url: url)
        request.setValue("image/avif,image/webp,image/png,image/jpeg,image/*;q=0.8", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        return downsample(data, maxPixel: maxPixel)
    }

    private static func downsample(_ data: Data, maxPixel: Int) -> Bitmap? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return Bitmap(cgImage: image)
    }
}

/// `AsyncImage` replacement backed by `ImageCache`: instant from memory on re-appear, downsampled to
/// `maxPixelSize` (in pixels; pass the display size in points times the screen scale), and the
/// download is cancelled-safe and shared between rows showing the same URL.
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    let maxPixelSize: CGFloat
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: (_ failed: Bool) -> Placeholder

    @State private var image: CGImage?
    @State private var failed = false

    init(url: URL?, maxPixelSize: CGFloat,
         @ViewBuilder content: @escaping (Image) -> Content,
         @ViewBuilder placeholder: @escaping (_ failed: Bool) -> Placeholder) {
        self.url = url
        self.maxPixelSize = maxPixelSize
        self.content = content
        self.placeholder = placeholder
        _image = State(initialValue: url.flatMap { ImageCache.shared.cached($0, maxPixelSize: maxPixelSize) })
    }

    var body: some View {
        Group {
            if let image {
                content(Image(decorative: image, scale: 1))
            } else {
                placeholder(failed)
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                failed = true
                return
            }
            if let hit = ImageCache.shared.cached(url, maxPixelSize: maxPixelSize) {
                image = hit
                failed = false
                return
            }
            let loaded = await ImageCache.shared.image(url, maxPixelSize: maxPixelSize)
            guard !Task.isCancelled else { return }
            image = loaded
            failed = loaded == nil
        }
    }
}
