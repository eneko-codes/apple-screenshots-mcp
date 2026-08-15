import Foundation

/// One row of `screenshots_list`.
///
/// Deliberately four fields. There is no thumbnail, no file path, no export URL and no
/// base64 payload, because no image is allowed to cross this server's boundary — see the
/// hard rule in CLAUDE.md. Everything here is metadata a caller needs in order to decide
/// which screenshot to ask for text from.
public struct Screenshot: Sendable, Equatable {
    /// `PHAsset.localIdentifier`. Opaque, and only meaningful to the library that issued
    /// it: rebuilding or restoring a library regenerates them, so an id from an earlier
    /// conversation is not safe to reuse without listing again.
    public let id: String
    public let creationDate: Date?
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(id: String, creationDate: Date?, pixelWidth: Int, pixelHeight: Int) {
        self.id = id
        self.creationDate = creationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// A page of `screenshots_list`, with the size of the full match set so a truncated
/// answer can say what it withheld.
public struct ScreenshotPage: Sendable, Equatable {
    public let results: [Screenshot]
    public let total: Int

    public init(results: [Screenshot], total: Int) {
        self.results = results
        self.total = total
    }
}

/// What OCR produced for one requested id.
///
/// Every requested id comes back with an outcome, because a bulk call must not fail
/// wholesale over a single stale identifier: the caller asked about five screenshots and
/// is entitled to the four that worked.
public struct TextExtraction: Sendable, Equatable {
    public let id: String
    /// Absent when the id did not resolve, so there is no asset to describe.
    public let screenshot: Screenshot?
    /// Recognised lines in reading order. Empty means Vision found no text at all, which
    /// is an ordinary outcome for a screenshot of a photograph or a blank window.
    public let lines: [String]
    /// Set when this id produced no text for a reason the caller needs to hear: an
    /// unknown id, or an asset whose pixels could not be read.
    public let failure: String?

    public init(id: String, screenshot: Screenshot?, lines: [String], failure: String?) {
        self.id = id
        self.screenshot = screenshot
        self.lines = lines
        self.failure = failure
    }

    /// Convenience for the ordinary case.
    public static func recognised(_ screenshot: Screenshot, lines: [String]) -> TextExtraction {
        TextExtraction(id: screenshot.id, screenshot: screenshot, lines: lines, failure: nil)
    }

    /// An id that is not in the Screenshots album — including an id that names a real
    /// photograph. Resolving ids inside the album is what keeps photographs unreachable,
    /// so this outcome is a feature and the message says so.
    public static func outOfScope(id: String) -> TextExtraction {
        TextExtraction(
            id: id, screenshot: nil, lines: [],
            failure: """
                no screenshot with this id is in the Screenshots album. Ids are resolved \
                inside that album only, so an id belonging to an ordinary photograph will \
                always land here. List again with screenshots_list — identifiers change \
                when a library is rebuilt or restored.
                """)
    }
}
