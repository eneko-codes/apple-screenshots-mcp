import Foundation

public enum ScreenshotsMCPServer {

    public static let name = "apple-screenshots-mcp"
    public static let version = "1.0.1"

    /// Returned from `initialize`. It carries what per-tool descriptions cannot state
    /// once: what the permission really covers, what this server refuses to carry across
    /// the boundary, and where the scope is enforced.
    public static let instructions = """
        Reads the macOS Screenshots smart album through PhotoKit and extracts text from it \
        with Vision. This is not a photo-library server.

        SCOPE. macOS grants Photos access for the whole library — there is no \
        screenshots-only permission. The narrowing to one album is done by this server's \
        code: exactly one fetch, hard-coded to \
        PHAssetCollectionSubtypeSmartAlbumScreenshots, with every id resolved inside that \
        album. A photograph cannot be listed or read, even by naming its identifier. Say \
        so plainly if someone asks what this can see; do not describe it as a system-level \
        restriction, because it is not one.

        NO IMAGE EVER CROSSES THIS BOUNDARY. No file paths, no thumbnails, no exports, no \
        base64. screenshots_list returns metadata and screenshot_extract_text returns text. \
        If someone wants to see a screenshot, they open Photos.

        Workflow: screenshots_list first, bounded by a date range, then \
        screenshot_extract_text with the ids it returned — several at once, not one call \
        each. Ids are opaque and cannot be typed by hand; they change when a library is \
        rebuilt or restored, so do not reuse one from an earlier conversation without \
        listing again.

        Dates accept three forms: 2026-08-12 (whole day), 2026-08-12T09:00 (local time), \
        or 2026-08-12T09:00:00+02:00 (explicit offset). 'to' is exclusive.

        OCR is a reading, not a transcript. Vision misreads small, stylised or low-contrast \
        type, and it auto-detects the language of each screenshot rather than using a \
        configured list. Attribute quoted text to the recognition, not to the screenshot.

        This server has no write tools and cannot alter the photo library. What may be used \
        at any moment is decided by the permission switches in the client, not by this code.
        """

    /// The store is a parameter so the whole server can be driven by a double. Nothing in
    /// this function opens a photo library by itself.
    public static func run(
        store: any ScreenshotStore = SystemScreenshotStore()
    ) async {
        Diagnostics.started(version: version)
        await serveStandardStreams(handler: handler(tools: ScreenshotTools(store: store)))
    }

    public static func handler(tools: ScreenshotTools) -> MCPHandler {
        MCPHandler(
            name: name, version: version, instructions: instructions,
            catalog: ToolCatalog.all(), tools: tools)
    }
}
