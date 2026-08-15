import Foundation
import ImageIO
import Photos
import Vision

/// The only file in this repository that talks to Apple.
///
/// It is short deliberately. Everything above the `ScreenshotStore` seam is proven against
/// an in-memory fake; nothing here can be, because it needs a real photo library and a TCC
/// grant. So the rule is that this file stays small enough to audit by reading — and the
/// thing most worth auditing is `fetchScreenshots`, the single query that defines what
/// this server can see.
public struct SystemScreenshotStore: ScreenshotStore {

    public init() {}

    // MARK: Permission

    /// `.readWrite` is not a choice. PhotoKit offers `.addOnly` and `.readWrite`, and
    /// `.addOnly` grants writing only — there is no read-only access level — so a server
    /// that reads must request the level that also permits writing. This one never writes:
    /// there is no `PHAssetChangeRequest` anywhere in this repository, and the seam has no
    /// method that could carry one.
    public func authorization() -> PhotoAuthorization {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    @discardableResult
    public func requestAccess() async -> PhotoAuthorization {
        Self.map(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    private static func map(_ status: PHAuthorizationStatus) -> PhotoAuthorization {
        switch status {
        case .authorized: return .authorized
        case .limited: return .limited
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        // A status this build does not know about is treated as no access. Failing closed
        // is the only safe reading of an unknown permission state.
        @unknown default: return .denied
        }
    }

    // MARK: The scope

    /// THE ONLY QUERY THIS SERVER MAKES AGAINST THE PHOTO LIBRARY.
    ///
    /// The subtype is a literal: `.smartAlbumScreenshots` is a smart album macOS maintains
    /// by itself, and nothing in this repository can name another one — no configuration
    /// setting reaches this call, and there is no second fetch to widen it. Every other
    /// method here goes through this function, so the scope of the whole server is these
    /// few lines. That is the point: it can be checked by reading rather than trusted.
    ///
    /// Two details are load-bearing:
    ///
    /// - Assets are fetched **in** the collection, never by identifier against the whole
    ///   library. `PHAsset.fetchAssets(withLocalIdentifiers:)` would resolve any asset on
    ///   the machine, photographs included, which is exactly the hole this avoids.
    /// - The `mediaType` predicate keeps a video out even if one somehow lands in the
    ///   album. OCR over a video frame is not something this server should quietly do.
    ///
    /// Sorted newest first, because that is the order the questions come in.
    private func fetchScreenshots(from: Date?, to: Date?) throws -> PHFetchResult<PHAsset> {
        guard
            let album = PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum, subtype: .smartAlbumScreenshots, options: nil
            ).firstObject
        else { throw ToolError.albumMissing }

        var predicates = [NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)]
        if let from { predicates.append(NSPredicate(format: "creationDate >= %@", from as NSDate)) }
        if let to { predicates.append(NSPredicate(format: "creationDate < %@", to as NSDate)) }

        let options = PHFetchOptions()
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return PHAsset.fetchAssets(in: album, options: options)
    }

    private static func describe(_ asset: PHAsset) -> Screenshot {
        Screenshot(
            id: asset.localIdentifier, creationDate: asset.creationDate,
            pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight)
    }

    // MARK: Reads

    public func count() async throws -> Int {
        try fetchScreenshots(from: nil, to: nil).count
    }

    public func list(from: Date?, to: Date?, limit: Int, offset: Int) async throws
        -> ScreenshotPage
    {
        let fetched = try fetchScreenshots(from: from, to: to)
        let total = fetched.count
        guard offset < total else { return ScreenshotPage(results: [], total: total) }

        // Indexing a PHFetchResult is lazy — only the assets in this page are ever
        // materialised, so paging a large album stays cheap.
        let upperBound = Swift.min(offset + limit, total)
        var results: [Screenshot] = []
        results.reserveCapacity(upperBound - offset)
        for index in offset..<upperBound {
            results.append(Self.describe(fetched.object(at: index)))
        }
        return ScreenshotPage(results: results, total: total)
    }

    public func extractText(ids: [String]) async throws -> [TextExtraction] {
        // Ids are matched inside the album rather than looked up in the library. An id
        // naming a photograph simply never matches, which is what makes "photographs are
        // unreachable" true of ids as well as of listings.
        let fetched = try fetchScreenshots(from: nil, to: nil)
        let wanted = Set(ids)
        var assets: [String: PHAsset] = [:]
        for index in 0..<fetched.count where assets.count < wanted.count {
            let asset = fetched.object(at: index)
            if wanted.contains(asset.localIdentifier) {
                assets[asset.localIdentifier] = asset
            }
        }

        var results: [TextExtraction] = []
        results.reserveCapacity(ids.count)
        for id in ids {
            guard let asset = assets[id] else {
                results.append(.outOfScope(id: id))
                continue
            }
            let screenshot = Self.describe(asset)
            do {
                let lines = try await recognizeText(in: asset)
                results.append(.recognised(screenshot, lines: lines))
            } catch {
                // One unreadable screenshot must not cost the caller the other four.
                results.append(
                    TextExtraction(
                        id: id, screenshot: screenshot, lines: [],
                        failure: error.localizedDescription))
            }
        }
        return results
    }

    // MARK: Vision

    /// Recognised lines, top to bottom. The image data is read here, used here and
    /// released here — it is never returned, cached or written anywhere, which is the
    /// promise the rest of the server is built on.
    ///
    /// `recognitionLanguages` is never set on the request. There used to be a setting for
    /// it; the owner's plug-and-play rule removed the configuration surface rather than
    /// freezing it to a fixed list, so this always runs Vision's own automatic language
    /// detection instead.
    private func recognizeText(in asset: PHAsset) async throws -> [String] {
        let (data, orientation) = try await imageData(for: asset)

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        // Synchronous and CPU-bound. This server answers one call at a time over stdio, so
        // the simple form is the honest one; a queue here would be machinery for a
        // concurrency this process does not have.
        try VNImageRequestHandler(data: data, orientation: orientation, options: [:])
            .perform([request])

        let observations = request.results ?? []
        return Self.readingOrder(observations)
            .compactMap { $0.topCandidates(1).first?.string }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Vision does not promise an order, so one is imposed rather than assumed — the same
    /// screenshot must produce the same text twice.
    ///
    /// Bounding boxes are normalised with the origin at the BOTTOM left, so a larger `midY`
    /// is higher on screen. Rows are banded before comparing because two boxes on the same
    /// visual line rarely share an exact centre, and comparing raw coordinates would
    /// interleave a line's own fragments.
    private static func readingOrder(_ observations: [VNRecognizedTextObservation])
        -> [VNRecognizedTextObservation]
    {
        func band(_ observation: VNRecognizedTextObservation) -> Int {
            Int((1 - observation.boundingBox.midY) * 200)
        }
        return observations.sorted { left, right in
            let leftBand = band(left)
            let rightBand = band(right)
            return leftBand == rightBand
                ? left.boundingBox.minX < right.boundingBox.minX
                : leftBand < rightBand
        }
    }

    // MARK: Pixels

    /// Full-resolution image data for one asset.
    ///
    /// `isNetworkAccessAllowed` is on because an iCloud Photos library keeps originals in
    /// the cloud and a screenshot that has been evicted locally would otherwise fail to
    /// read at all. That is a download into this process's memory, not an upload: nothing
    /// leaves the machine.
    private func imageData(for asset: PHAsset) async throws -> (Data, CGImagePropertyOrientation) {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        // .highQualityFormat delivers a single result. The default, .opportunistic, may
        // call the handler twice — see SingleResume below for why that matters.
        options.deliveryMode = .highQualityFormat

        return try await withCheckedThrowingContinuation { continuation in
            let resume = SingleResume(continuation)
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) {
                data, _, orientation, info in
                if let data {
                    resume.resume(with: .success((data, orientation)))
                } else if let failure = info?[PHImageErrorKey] as? NSError {
                    resume.resume(with: .failure(ToolError.storeFailure(failure.localizedDescription)))
                } else {
                    resume.resume(
                        with: .failure(
                            ToolError.storeFailure(
                                "Photos returned no image data for this asset. If the library "
                                    + "is in iCloud, the original may not have finished "
                                    + "downloading.")))
                }
            }
        }
    }
}

/// Resumes a continuation exactly once.
///
/// PhotoKit documents that `.highQualityFormat` delivers a single result, but nothing
/// enforces it, and a `CheckedContinuation` resumed twice traps — which would take the
/// whole server down rather than fail one OCR call. The lock is the cheapest way to make
/// that impossible.
private final class SingleResume<Success>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Success, any Error>?

    init(_ continuation: CheckedContinuation<Success, any Error>) {
        self.continuation = continuation
    }

    /// `sending` because the result is built inside PhotoKit's callback and handed over
    /// wholesale; the compiler needs to know the caller keeps no reference to it.
    func resume(with result: sending Result<Success, any Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
