import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a request needs from the pasteboard. Reading only what's needed keeps probes cheap
/// and avoids touching data for a targets check.
public enum Need: Sendable {
    case types
    case image
    case text
}

/// A copy of the parts of the pasteboard a request needs. Built on the main thread.
public struct Snapshot: Sendable {
    public var changeCount: Int
    public var types: [String]
    public var fileURLs: [URL]
    public var png: Data?
    public var tiff: Data?
    public var string: String?

    public init(changeCount: Int, types: [String], fileURLs: [URL] = [], png: Data? = nil, tiff: Data? = nil, string: String? = nil) {
        self.changeCount = changeCount
        self.types = types
        self.fileURLs = fileURLs
        self.png = png
        self.tiff = tiff
        self.string = string
    }

    /// nspasteboard.org markers set by password managers. Anything marked is never served.
    public static let concealedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "com.agilebits.onepassword",
    ]

    public var isConcealed: Bool { types.contains(where: Snapshot.concealedTypes.contains) }

    public var hasText: Bool { types.contains(NSPasteboard.PasteboardType.string.rawValue) }

    /// Image-ness from types and file URLs alone; reads no image data.
    public var hasImage: Bool {
        if let url = fileURLs.first { return ImageSelect.isImageFile(url) }
        return types.contains(NSPasteboard.PasteboardType.png.rawValue)
            || types.contains(NSPasteboard.PasteboardType.tiff.rawValue)
    }

    @MainActor
    public static func read(from pb: NSPasteboard, need: Need) -> Snapshot {
        let types = (pb.types ?? []).map(\.rawValue)
        var snap = Snapshot(changeCount: pb.changeCount, types: types)
        if snap.isConcealed { return snap }
        if types.contains(NSPasteboard.PasteboardType.fileURL.rawValue) {
            let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
            snap.fileURLs = urls ?? []
        }
        switch need {
        case .types:
            break
        case .image:
            if snap.fileURLs.isEmpty {
                snap.png = pb.data(forType: .png)
                if snap.png == nil { snap.tiff = pb.data(forType: .tiff) }
            }
        case .text:
            snap.string = pb.string(forType: .string)
        }
        return snap
    }
}

public enum ImageSelect {
    public static let maxEdge = 2000
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp"]

    public static func isImageFile(_ url: URL) -> Bool {
        url.isFileURL && imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Picks the image to serve: an image file URL, then public.png, then public.tiff.
    /// A non-image file URL means no image, so a Finder file icon is never sent.
    public static func pngData(from snap: Snapshot) -> Data? {
        if let url = snap.fileURLs.first {
            guard isImageFile(url), let data = try? Data(contentsOf: url) else { return nil }
            return normalize(data)
        }
        if let png = snap.png { return normalize(png) }
        if let tiff = snap.tiff { return normalize(tiff) }
        return nil
    }

    /// PNG with a long edge of at most 2000 px. A PNG already within that size passes through unchanged.
    public static func normalize(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let longEdge = max(w, h)
        let isPNG = (CGImageSourceGetType(src) as String?) == UTType.png.identifier
        if isPNG && longEdge <= maxEdge { return data }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(longEdge, maxEdge),
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

/// Tracks when the pasteboard last changed. Content already there at startup counts as stale
/// until the change count moves.
public final class Freshness: @unchecked Sendable {
    private var baseline: Int?
    private var lastChange: Date?
    private let lock = NSLock()

    public init() {}

    public func observe(changeCount: Int, now: Date) {
        lock.withLock {
            guard let b = baseline else {
                baseline = changeCount
                return
            }
            if changeCount != b {
                baseline = changeCount
                lastChange = now
            }
        }
    }

    /// window nil means no time limit (a change since startup is still required).
    public func isFresh(now: Date, window: TimeInterval?) -> Bool {
        lock.withLock {
            guard let lastChange else { return false }
            guard let window else { return true }
            return now.timeIntervalSince(lastChange) <= window
        }
    }
}
