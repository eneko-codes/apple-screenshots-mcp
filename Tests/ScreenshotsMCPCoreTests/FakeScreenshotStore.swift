import Foundation

@testable import ScreenshotsMCPCore

/// In-memory `ScreenshotStore` for the tests.
///
/// Every fixture here is invented. The test suite must never reach the real photo
/// library: see the hard rule in CLAUDE.md.
final class FakeScreenshotStore: ScreenshotStore, @unchecked Sendable {
    var status: PhotoAuthorization
    var screenshots: [Screenshot]
    /// Recognised lines by screenshot id. An id absent from here is a screenshot Vision
    /// found no text in, which is an ordinary outcome rather than an error.
    var text: [String: [String]]
    /// Ids that resolve but whose pixels cannot be read — the iCloud-eviction case.
    var unreadable: Set<String> = []
    private(set) var accessRequests = 0
    /// What dispatch actually asked for, so the suite can prove the ceiling and the
    /// deduplication happen before any OCR would run.
    private(set) var extractCalls: [[String]] = []

    init(
        status: PhotoAuthorization = .authorized,
        screenshots: [Screenshot] = Fixtures.screenshots,
        text: [String: [String]] = Fixtures.text
    ) {
        self.status = status
        self.screenshots = screenshots
        self.text = text
    }

    func authorization() -> PhotoAuthorization { status }

    @discardableResult
    func requestAccess() async -> PhotoAuthorization {
        accessRequests += 1
        if status == .notDetermined { status = .authorized }
        return status
    }

    func count() async throws -> Int { screenshots.count }

    func list(from: Date?, to: Date?, limit: Int, offset: Int) async throws -> ScreenshotPage {
        var matches = screenshots
        if let from { matches = matches.filter { ($0.creationDate ?? .distantPast) >= from } }
        if let to { matches = matches.filter { ($0.creationDate ?? .distantPast) < to } }
        // Newest first, as the real store's sort descriptor does.
        matches.sort { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
        let page = matches.dropFirst(offset).prefix(limit)
        return ScreenshotPage(results: Array(page), total: matches.count)
    }

    func extractText(ids: [String]) async throws -> [TextExtraction] {
        extractCalls.append(ids)

        return ids.map { id in
            guard let screenshot = screenshots.first(where: { $0.id == id }) else {
                return .outOfScope(id: id)
            }
            if unreadable.contains(id) {
                return TextExtraction(
                    id: id, screenshot: screenshot, lines: [],
                    failure: "Photos returned no image data for this asset.")
            }
            return .recognised(screenshot, lines: text[id] ?? [])
        }
    }
}

enum Fixtures {
    /// Fixed so date filtering is decided by the fixtures, not by when the suite runs.
    static let timeZone = TimeZone(identifier: "Europe/Madrid")!

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0)
        -> Date
    {
        calendar.date(
            from: DateComponents(
                timeZone: timeZone, year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }

    /// An id in the shape PhotoKit issues, so nothing in the suite accidentally relies on
    /// ids being short or typeable.
    static func identifier(_ suffix: String) -> String {
        "8F1C1A2E-0000-4A0B-9C11-\(suffix)/L0/001"
    }

    static let oldest = identifier("000000000001")
    static let middle = identifier("000000000002")
    static let newest = identifier("000000000003")
    static let blank = identifier("000000000004")
    /// Never in `screenshots`: it stands for a real photograph's identifier, which must
    /// never resolve.
    static let photograph = identifier("00000000ffff")

    static let screenshots: [Screenshot] = [
        Screenshot(
            id: oldest, creationDate: date(2026, 7, 2, 9, 15),
            pixelWidth: 2940, pixelHeight: 1912),
        Screenshot(
            id: middle, creationDate: date(2026, 8, 3, 18, 40),
            pixelWidth: 1179, pixelHeight: 2556),
        Screenshot(
            id: newest, creationDate: date(2026, 8, 9, 11, 5),
            pixelWidth: 2940, pixelHeight: 1912),
        Screenshot(
            id: blank, creationDate: date(2026, 8, 9, 11, 6),
            pixelWidth: 800, pixelHeight: 600),
    ]

    /// `blank` is deliberately absent: a screenshot with no recognisable text.
    static let text: [String: [String]] = [
        oldest: ["Boarding pass", "Seat 14A", "Gate B22"],
        middle: ["Total 42,30 €", "IVA incluido"],
        newest: ["Error 500", "Internal Server Error"],
    ]
}
