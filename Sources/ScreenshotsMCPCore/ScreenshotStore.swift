import Foundation

/// The seam between the tool layer and PhotoKit.
///
/// Everything above this protocol is exercised by the tests against an in-memory double;
/// everything below it can only be verified against a real photo library. Keeping the
/// boundary this thin is what makes the untested surface small enough to check by hand —
/// and it is what lets the suite run without ever opening the owner's Photos library.
///
/// The protocol is also the scope statement. There is no `photos()`, no `albums()`, no
/// `export()` and no method that returns image bytes: the only shapes that can cross are
/// `Screenshot` metadata and recognised text. A future tool cannot quietly widen the
/// server without widening this file first, which is exactly the review this design wants
/// to force.
public protocol ScreenshotStore: Sendable {
    func authorization() -> PhotoAuthorization

    @discardableResult
    func requestAccess() async -> PhotoAuthorization

    /// How many assets the Screenshots album holds. `screenshots_status` reports it so a
    /// caller can tell "no matches in that range" apart from "the album is empty".
    func count() async throws -> Int

    /// Newest first. `offset` indexes into the matches; the album is finite and already
    /// ordered, so no cursor is needed.
    func list(from: Date?, to: Date?, limit: Int, offset: Int) async throws -> ScreenshotPage

    /// Runs OCR over each id and returns one outcome per id, in the order given.
    ///
    /// Ids that are not in the Screenshots album come back as `.outOfScope` rather than
    /// throwing: an id naming a photograph must fail, but it must fail per-id and say why.
    /// There is no language parameter: recognition always uses Vision's own automatic
    /// language detection.
    func extractText(ids: [String]) async throws -> [TextExtraction]
}
